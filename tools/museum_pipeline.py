"""Org Museum source validation, isolated builds and source-only Git sync.

Standard library only. No input note code is ever executed.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
from contextlib import contextmanager
from collections import Counter
from urllib.parse import unquote, urlsplit
from html.parser import HTMLParser

KINDS = {"programming", "knowledge", "reading", "ideas"}
ID = re.compile(r"[a-z0-9][a-z0-9-]{7,79}\Z")
SECRETS = [
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16})\b"),
    re.compile(r"(?im)^\s*(?:export\s+)?(?:[A-Z_]*API_KEY|[A-Z_]*TOKEN|PASSWORD|SECRET)\s*[=:]\s*[\"']?(?!\[|<|\$|YOUR_|your_|example|REDACTED)[A-Za-z0-9_+/-]{12,}"),
    re.compile(r"(?i)https?://[^\s/]+:[^\s/@]+@"),
    re.compile(r"(?i)\b[A-Z]:[\\/](?:Users|Documents and Settings)[\\/]|file:///|\\\\[A-Za-z0-9_.-]+\\"),
]
ASSET_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".pdf", ".csv", ".json", ".txt", ".sql", ".py", ".sh"}

class Invalid(ValueError):
    pass

def git(root: Path, *args: str, binary=False):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if result.returncode:
        # Never include arbitrary content or credentials from Git diagnostics.
        error = result.stderr.decode("utf-8", "replace").lower()
        if any(x in error for x in ("authentication", "permission denied", "403", "401")):
            raise Invalid("authentication: GitHub access must be restored")
        if any(x in error for x in ("could not resolve", "unable to access", "connection", "timed out")):
            raise Invalid("network: source changes remain pending")
        if any(x in error for x in ("non-fast-forward", "fetch first", "cannot lock ref", "incorrect old value provided")):
            raise Invalid("retry: remote changed; source changes remain pending")
        raise Invalid("git: operation failed; source changes remain preserved")
    return result.stdout if binary else result.stdout.decode("utf-8").strip()

def privacy(text: str, label: str):
    for pattern in SECRETS:
        if pattern.search(text):
            raise Invalid(f"privacy: {label} contains a credential or private location (content withheld)")

def within(root: Path, relative: str) -> Path:
    if "\\" in relative or "\x00" in relative or ":" in relative:
        raise Invalid("path: unsupported path")
    parts = Path(relative).parts
    if Path(relative).is_absolute() or ".." in parts:
        raise Invalid("path: path escapes source root")
    path = root / relative
    if any(p.is_symlink() for p in (path, *path.parents)) or not path.resolve().is_relative_to(root.resolve()):
        raise Invalid("path: symbolic links and outside paths are unsupported")
    return path

def metadata(text: str):
    headers = {}
    blocks = []
    for line in text.splitlines():
        begin = re.match(r"\s*#\+begin_(\w+)\b", line, re.I)
        end = re.match(r"\s*#\+end_(\w+)\b", line, re.I)
        if begin:
            if blocks and blocks[-1] in {"src", "example", "export"}:
                continue
            if begin[1].lower() == "export" and re.search(r"\shtml\b", line, re.I):
                raise Invalid("org: raw active HTML is unsupported")
            blocks.append(begin[1].lower())
            continue
        if end:
            if blocks and end[1].lower() == blocks[-1]:
                blocks.pop()
            elif not blocks or blocks[-1] not in {"src", "example"}:
                raise Invalid("org: mismatched block end")
            continue
        if blocks:
            continue
        if re.search(r"@@html:|<script\b", line, re.I):
            raise Invalid("org: raw active HTML is unsupported")
        keyword = re.match(r"\s*#\+([\w_]+):\s*(.*)$", line, re.I)
        if keyword:
            key, value = keyword[1].upper(), keyword[2].strip()
            if key in {"INCLUDE", "SETUPFILE", "BIND", "HTML_HEAD", "HTML_HEAD_EXTRA", "MACRO"}:
                raise Invalid(f"org: active export directive {key} is unsupported")
            if key in headers and key in {"TITLE", "WIKI_ID", "CATEGORY", "DATE", "FILETAGS", "SOURCE", "INGEST_ID"}:
                raise Invalid(f"org: duplicate {key}")
            headers[key] = value
    if blocks:
        raise Invalid("org: unterminated block")
    return headers

def prose(text):
    return re.sub(r"(?ims)^\s*#\+begin_(src|example)\b[^\n]*\n.*?^\s*#\+end_\1\s*$", "", text)

def validate(root: Path):
    root = root.resolve()
    records, seen = [], set()
    notes = root / "notes"
    if not notes.exists():
        return records
    for path in sorted(notes.rglob("*")):
        relative = path.relative_to(root).as_posix()
        within(root, relative)
        if not path.is_file():
            continue
        if path.suffix != ".org":
            raise Invalid(f"path: unsupported source file {relative}")
        parts = path.relative_to(notes).parts
        if len(parts) != 3 or parts[0] not in KINDS or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", parts[1]):
            raise Invalid(f"path: expected notes/<kind>/<topic>/<id>.org: {relative}")
        text = path.read_text(encoding="utf-8-sig")
        privacy(text, relative)
        meta = metadata(text)
        for key in ("TITLE", "WIKI_ID", "CATEGORY", "DATE", "FILETAGS", "SOURCE", "INGEST_ID"):
            if not meta.get(key):
                raise Invalid(f"org: missing {key} in {relative}")
        note_id = meta["WIKI_ID"]
        if not ID.fullmatch(note_id) or note_id != path.stem or note_id in seen:
            raise Invalid("org: note ID must be unique and match the filename")
        seen.add(note_id)
        if not ID.fullmatch(meta["INGEST_ID"]):
            raise Invalid("org: invalid stable ingestion ID")
        import datetime
        try:
            datetime.date.fromisoformat(meta["DATE"])
        except ValueError as error:
            raise Invalid("org: DATE must be an ISO calendar date") from error
        if meta.get("WIKI_STATUS", "published") not in {"published", "draft"}:
            raise Invalid("org: unsupported publication status")
        for target in re.findall(r"\[\[file:([^]\n]+)\]", prose(text)):
            target = unquote(target.split("::", 1)[0])
            destination = (path.parent / target).resolve()
            if not destination.is_relative_to(root) or not destination.is_file() or destination.is_symlink():
                raise Invalid(f"link: unresolved or outside file link in {relative}")
            if not (destination.is_relative_to(notes) or destination.is_relative_to(root / "note-assets")):
                raise Invalid("link: file links must resolve to notes or note-assets")
        records.append({"id": note_id, "ingestId": meta["INGEST_ID"], "path": relative,
                        "title": meta["TITLE"], "status": meta.get("WIKI_STATUS", "published"),
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "href": "pages/collected/" + path.relative_to(notes).with_suffix(".html").as_posix()})
    known_ids = seen | {p["id"] for p in legacy_records(root)}
    for record in records:
        text = prose((root / record["path"]).read_text(encoding="utf-8-sig"))
        for target in re.findall(r"\[\[wiki:([^]\n]+)\]", text):
            if target.split("#", 1)[0] not in known_ids:
                raise Invalid(f"link: unresolved wiki link in {record['path']}")
    for path in sorted((root / "note-assets").rglob("*")):
        within(root, path.relative_to(root).as_posix())
        if path.is_file():
            if path.suffix.lower() not in ASSET_EXTENSIONS or path.stat().st_size > 20 * 1024 * 1024:
                raise Invalid("asset: unsupported format or attachment larger than 20 MiB")
            if path.suffix.lower() in {".csv", ".json", ".txt", ".sql", ".py", ".sh"}:
                privacy(path.read_text(encoding="utf-8"), "attachment")
    return records

def legacy_records(root: Path):
    source = root / "resources/org-museum-related-data.js"
    if not source.exists():
        return []
    text = source.read_text(encoding="utf-8")
    payload = json.JSONDecoder().raw_decode(text[text.index("=") + 1:].lstrip())[0]
    result = []
    for page in payload.get("pages", []):
        href = page["href"]
        if href.startswith("pages/collected/"):
            continue
        if not href.startswith("pages/") or not within(root, href).is_file():
            raise Invalid("legacy: catalog references a missing or invalid page")
        result.append({k: page.get(k) for k in ("id", "title", "category", "tags", "description", "modifiedDate", "linksTo", "href")})
    return result

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()
    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if attributes.get("id"):
            self.ids.add(attributes["id"])
        for key in ("href", "src", "poster"):
            if attributes.get(key):
                self.links.append(attributes[key])

def check_site(output: Path, new_records: list):
    parsed = {}
    # Preserved pages can have pre-existing broken links. Check regenerated pages
    # and shared entrypoints, without claiming to repair historical content.
    files = [output / r["href"] for r in new_records if r["status"] == "published"]
    files += [output / x for x in ("index.html", "graph.html", "timeline.html", "related.html")]
    for path in files:
        if not path.is_file():
            raise Invalid("build: a required page is missing")
        text = path.read_text(encoding="utf-8")
        privacy(text, "generated HTML")
        parser = Links()
        parser.feed(text)
        for link in parser.links:
            url = urlsplit(link)
            if url.scheme or url.netloc or not url.path:
                continue
            destination = (path.parent / unquote(url.path)).resolve()
            if not destination.is_relative_to(output.resolve()) or not destination.is_file():
                raise Invalid(f"build: unresolved link from {path.relative_to(output)}")
            if url.fragment and destination.suffix == ".html":
                if destination not in parsed:
                    target = Links()
                    target.feed(destination.read_text(encoding="utf-8"))
                    parsed[destination] = target.ids
                if unquote(url.fragment) not in parsed[destination]:
                    raise Invalid(f"build: unresolved fragment from {path.relative_to(output)}")

def build(root: Path, engine: Path, output: Path, emacs: str):
    root, engine, output = root.resolve(), engine.resolve(), output.resolve()
    if output.exists():
        raise Invalid("build: output must be a new directory")
    records = validate(root)
    legacy = legacy_records(root)
    with tempfile.TemporaryDirectory(prefix="museum-build-") as staging:
        stage = Path(staging)
        source, candidate = stage / "source", stage / "site"
        source.mkdir()
        candidate.mkdir()
        # A tracked legacy snapshot is retained; source/config/private metadata
        # are never copied into the Pages artifact.
        for name in ("pages", "resources", "assets"):
            if (root / name).exists():
                shutil.copytree(root / name, candidate / name)
        for name in (".nojekyll", "CNAME", "ai-center.html", "ai-public.json", "assets.json"):
            if (root / name).is_file():
                shutil.copy2(root / name, candidate / name)
        if (candidate / "pages/collected").exists():
            collected = (candidate / "pages/collected").resolve()
            if not collected.is_relative_to(stage.resolve()):
                raise Invalid("build: collected output escapes temporary staging")
            shutil.rmtree(collected)
        for name in ("notes", "note-assets"):
            if (root / name).exists():
                shutil.copytree(root / name, source / name)
        (source / "notes").mkdir(exist_ok=True)
        for path in (source / "notes").rglob("*.org"):
            rel = path.relative_to(source).as_posix()
            try:
                timestamp = int(git(root, "log", "-1", "--format=%ct", "--", rel))
                os.utime(path, (timestamp, timestamp))
            except (Invalid, ValueError):
                pass
        old_assets = json.loads((candidate / "assets.json").read_text(encoding="utf-8")) if (candidate / "assets.json").exists() else None
        preserved = {p.relative_to(candidate).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in (candidate / "pages").rglob("*.html")} if (candidate / "pages").exists() else {}
        virtual = source / "_legacy"
        virtual.mkdir()
        for number, page in enumerate(legacy):
            path = virtual / f"{number}.org"
            page["sourcePath"] = str(path)
            body = "\n".join(f"[[wiki:{target}]]" for target in (page.get("linksTo") or []))
            path.write_text(f"#+TITLE: {page['title']}\n#+WIKI_ID: {page['id']}\n\n{body}\n", encoding="utf-8")
        legacy_path = stage / "legacy.json"
        legacy_path.write_text(json.dumps(legacy, ensure_ascii=False), encoding="utf-8")
        env = dict(os.environ, MUSEUM_SOURCE_ROOT=str(source), MUSEUM_OUTPUT=str(candidate), MUSEUM_LEGACY=str(legacy_path))
        result = subprocess.run([emacs, "-Q", "--batch", "-L", str(engine), "-l", str(engine / "org-museum-pipeline.el"), "-f", "org-museum-pipeline-batch"], env=env, capture_output=True, timeout=600)
        if result.returncode:
            # Export errors might contain original content; keep them local.
            raise Invalid("build: Emacs export failed: " + result.stderr.decode("utf-8", "replace")[-3500:])
        for relative, digest in preserved.items():
            if hashlib.sha256((candidate / relative).read_bytes()).hexdigest() != digest:
                raise Invalid("legacy: an existing published page changed")
        if old_assets:
            current = json.loads((candidate / "assets.json").read_text(encoding="utf-8"))
            if isinstance(current.get("assets"), list) and isinstance(old_assets.get("assets"), list):
                merged = {item["id"]: item for item in old_assets["assets"]}
                merged.update({item["id"]: item for item in current["assets"]})
                current["assets"] = list(merged.values())
                (candidate / "assets.json").write_text(json.dumps(current, ensure_ascii=False), encoding="utf-8")
        check_site(candidate, records)
        sha = git(root, "rev-parse", "HEAD")
        repository = json.loads((root / "museum.json").read_text(encoding="utf-8")).get("repository", "lovemoganna/org-notes")
        for record in records:
            record["sourceUrl"] = f"https://raw.githubusercontent.com/{repository}/{sha}/{record['path']}"
        receipt = {"schemaVersion": 1, "repository": repository, "sourceCommit": sha, "notes": records, "legacyPages": len(legacy)}
        (candidate / "museum-release.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding="utf-8")
        for record in records:
            if record["status"] == "published":
                path = candidate / record["href"]
                text = path.read_text(encoding="utf-8")
                marker = f'<meta name="museum-source-commit" content="{sha}"><meta name="museum-note-sha256" content="{record["sha256"]}">'
                marker += (f'<meta name="museum-wiki-id" content="{html.escape(record["id"], quote=True)}">'
                           f'<meta name="museum-source-path" content="{html.escape(record["path"], quote=True)}">'
                           f'<link rel="alternate" type="text/org" href="{html.escape(record["sourceUrl"], quote=True)}">')
                path.write_text(text.replace("</head>", marker + "</head>", 1), encoding="utf-8")
        (candidate / ".nojekyll").touch()
        for path in candidate.rglob("*"):
            if path.is_file() and path.suffix.lower() in {".html", ".js", ".css", ".json", ".txt"}:
                text = path.read_text(encoding="utf-8")
                baseline = root / path.relative_to(candidate)
                old = baseline.read_text(encoding="utf-8") if baseline.is_file() else ""
                # Vendor regexes and already-public examples may mention file:
                # URLs. Preserve existing artifacts; reject any new findings.
                for pattern in SECRETS:
                    if Counter(match.group(0) for match in pattern.finditer(text)) - Counter(match.group(0) for match in pattern.finditer(old)):
                        raise Invalid(f"privacy: new finding in {path.relative_to(candidate)} (content withheld)")
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(candidate, output)
        return receipt

def blob(root: Path, ref: str, relative: str):
    result = subprocess.run(["git", "-C", str(root), "cat-file", "--filters", f"{ref}:{relative}"], capture_output=True)
    return result.stdout if result.returncode == 0 else None

@contextmanager
def sync_lock(root: Path):
    "An OS lock is released even if the synchronizer crashes."
    lock_path = Path(git(root, "rev-parse", "--absolute-git-dir")) / "museum-source-sync.lock"
    with lock_path.open("a+b") as handle:
        handle.seek(0)
        handle.write(b"0")
        handle.flush()
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise Invalid("retry: another source sync is running") from error
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

def reconcile(root, base, head, snapshots):
    if git(root, "rev-parse", "HEAD") != base or git(root, "diff", "--cached", "--name-only"):
        raise Invalid("conflict: checkout changed during sync; local content preserved")
    changed = git(root, "diff", "--name-only", "-z", base, head, binary=True).split(b"\0")
    replacements = []
    for encoded in changed:
        if not encoded:
            continue
        relative = encoded.decode("utf-8")
        target = within(root, relative)
        before = target.read_bytes() if target.is_file() else None
        if relative in snapshots:
            continue
        if before != blob(root, base, relative):
            raise Invalid("conflict: unrelated local edit preserved, reconcile required")
        replacements.append((target, blob(root, head, relative)))
    for target, replacement in replacements:
        if replacement is None:
            target.unlink(missing_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(replacement)
    git(root, "update-ref", "refs/heads/main", head, base)
    git(root, "read-tree", head)

def sync(root: Path):
    with sync_lock(root.resolve()):
        return sync_locked(root)

def sync_locked(root: Path):
    root = root.resolve()
    validate(root)
    config = json.loads((root / "museum.json").read_text(encoding="utf-8"))
    if config.get("publishMode") != "actions" or config.get("repository") != "lovemoganna/org-notes":
        raise Invalid("sync: source repository is not configured")
    remote = git(root, "config", "--get", "remote.origin.url")
    if remote.rstrip("/").removesuffix(".git") not in {"https://github.com/lovemoganna/org-notes", "git@github.com:lovemoganna/org-notes"}:
        raise Invalid("sync: unexpected remote")
    if git(root, "branch", "--show-current") != "main" or git(root, "diff", "--cached", "--name-only"):
        raise Invalid("sync: requires main and an empty staging area")
    base = git(root, "rev-parse", "HEAD")
    status = git(root, "status", "--porcelain=v1", "-z", "--", "notes/", "note-assets/", binary=True)
    paths = []
    for entry in status.split(b"\0"):
        if not entry:
            continue
        if b"R" in entry[:2] or b"C" in entry[:2]:
            raise Invalid("sync: use stable filenames; renames require explicit review")
        path = entry[3:].decode("utf-8")
        if path.endswith("/"):
            paths.extend(p.relative_to(root).as_posix() for p in within(root, path).rglob("*") if p.is_file())
        else:
            paths.append(path)
    paths = sorted(set(paths))
    snapshots = {p: within(root, p).read_bytes() if within(root, p).is_file() else None for p in paths}
    git(root, "fetch", "origin", "main")
    head = git(root, "rev-parse", "origin/main")
    if subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", base, head], capture_output=True).returncode:
        raise Invalid("sync: local history is ahead or diverged; no commits discarded")
    if not paths:
        reconcile(root, base, head, {})
        return {"status": "unchanged", "commit": head}
    for relative in paths:
        remote_content = blob(root, head, relative)
        if remote_content != blob(root, base, relative) and remote_content != snapshots[relative]:
            raise Invalid(f"conflict: {relative}; local content preserved")
    with tempfile.TemporaryDirectory(prefix="museum-sync-") as temporary:
        checkout = Path(temporary) / "checkout"
        git(root, "worktree", "add", "--detach", str(checkout), head)
        try:
            for relative, content in snapshots.items():
                target = within(checkout, relative)
                if content is None:
                    target.unlink(missing_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(content)
            validate(checkout)
            git(checkout, "add", "--", *paths)
            if git(checkout, "diff", "--cached", "--name-only"):
                git(checkout, "commit", "-m", "notes: sync saved knowledge sources")
                head = git(checkout, "rev-parse", "HEAD")
                git(checkout, "push", "origin", f"{head}:refs/heads/main")
            # Keep note edits made while sync ran; they remain dirty for retry.
            reconcile(root, base, head, snapshots)
            return {"status": "submitted", "commit": head}
        finally:
            if checkout.resolve().is_relative_to(Path(temporary).resolve()):
                git(root, "worktree", "remove", "--force", str(checkout))

def verify_live(site: str, commit: str, attempts=12, interval=15):
    "Attest real deployed bytes, so Chat can read proof using GitHub logs."
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise Invalid("verify: invalid source commit")
    site = site.rstrip("/") + "/"
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(site + "museum-release.json?commit=" + commit,
                                            headers={"Cache-Control": "no-cache"})
            with urllib.request.urlopen(request, timeout=20) as response:
                receipt = json.load(response)
            if receipt.get("sourceCommit") != commit:
                raise Invalid("verify: CDN has not served this source version yet")
            for note in receipt["notes"]:
                if note["status"] != "published":
                    continue
                href = note["href"]
                if not href.startswith("pages/collected/") or ".." in Path(href).parts:
                    raise Invalid("verify: invalid published page path")
                with urllib.request.urlopen(site + href + "?commit=" + commit, timeout=20) as response:
                    page = response.read().decode("utf-8")
                if (f'name="museum-source-commit" content="{commit}"' not in page or
                    f'name="museum-note-sha256" content="{note["sha256"]}"' not in page):
                    raise Invalid("verify: page does not contain the expected content version")
            receipt["status"] = "published"
            receipt["siteUrl"] = site
            return receipt
        except (OSError, ValueError) as error:
            if attempt == attempts - 1:
                raise Invalid("verify: live page version could not be confirmed") from error
            time.sleep(interval)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["validate", "build", "sync", "verify"])
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--engine", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--emacs", default="emacs")
    parser.add_argument("--site", default="https://lovemoganna.github.io/org-notes/")
    parser.add_argument("--commit")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            result = {"status": "valid", "notes": validate(args.root)}
        elif args.command == "sync":
            result = sync(args.root)
        elif args.command == "verify":
            if not args.commit:
                parser.error("verify requires --commit")
            result = verify_live(args.site, args.commit)
        else:
            if not args.engine or not args.output:
                parser.error("build requires --engine and --output")
            result = build(args.root, args.engine, args.output, args.emacs)
        print(("MUSEUM-PUBLISHED-RECEIPT " if args.command == "verify" else "") + json.dumps(result, ensure_ascii=False))
    except (Invalid, OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False))
        raise SystemExit(1)

if __name__ == "__main__":
    main()
