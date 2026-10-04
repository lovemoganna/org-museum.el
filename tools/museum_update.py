"""Resolve a published Museum URL to an existing Git source and update it in place.

Reforging is performed by the existing note-reforge skill, never by this module.
HTML's filtered Org view is evidence, not a replacement for the complete source.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.request
import uuid
from urllib.parse import unquote, urlsplit, urlunsplit
from html.parser import HTMLParser

import museum_pipeline as p

class PageSource(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta, self.source, self.alternate = {}, [], None
        self.in_source = self.in_code = False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "meta" and a.get("name", "").startswith("museum-"):
            if a["name"] in self.meta:
                raise p.Invalid("resolve: ambiguous page identity")
            self.meta[a["name"]] = a.get("content")
        if tag == "link" and a.get("rel") == "alternate" and a.get("type") == "text/org":
            self.alternate = a.get("href")
        if tag == "pre" and "museum-org-source" in a.get("class", "").split():
            self.in_source = True
        if tag == "code" and self.in_source:
            self.in_code = True
    def handle_endtag(self, tag):
        if tag == "code": self.in_code = False
        if tag == "pre": self.in_source = False
    def handle_data(self, data):
        if self.in_code: self.source.append(data)

def canonical_url(url, site):
    "Query and fragment are presentation state, never source identity."
    target, base = urlsplit(url), urlsplit(site.rstrip("/") + "/")
    try:
        origin = lambda u: (u.scheme.lower(), (u.hostname or "").lower(), u.port or (443 if u.scheme == "https" else 80))
        if target.username or target.password or origin(target) != origin(base) or base.scheme not in {"http", "https"}:
            raise p.Invalid("resolve: URL is outside the configured Museum site")
    except ValueError as error:
        raise p.Invalid("resolve: invalid URL") from error
    path, prefix = unquote(target.path), unquote(base.path)
    if (not path.startswith(prefix) or "\\" in path or "\x00" in path or
            any(part in {".", ".."} for part in path.split("/")) or "%" in path):
        raise p.Invalid("resolve: unsafe or ambiguous page path")
    href = path[len(prefix):]
    if not href.startswith("pages/") or not href.endswith(".html"):
        raise p.Invalid("resolve: URL is not a Museum article")
    return urlunsplit((base.scheme, base.netloc, prefix + href, "", "")), href

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise p.Invalid("resolve: redirected source identity must be checked explicitly")

def read_url(url):
    with urllib.request.build_opener(NoRedirect).open(url, timeout=20) as response:
        return response.read().decode("utf-8-sig")

def source_blob(root, commit, path):
    p.within(root, path)
    if not path.endswith(".org"):
        raise p.Invalid("resolve: source is not an Org file")
    result = subprocess.run(["git", "-C", str(root), "show", f"{commit}:{path}"], capture_output=True)
    if result.returncode:
        raise p.Invalid("resolve: original Org file is absent from Git; update stopped, no note created")
    return result.stdout

def resolve(root, url):
    root = root.resolve()
    config = json.loads((root / "museum.json").read_text(encoding="utf-8"))
    if config.get("repository") != "lovemoganna/org-notes" or config.get("publishMode") != "actions":
        raise p.Invalid("resolve: authoritative source repository is not configured")
    canonical, href = canonical_url(url, config["siteUrl"])
    page = PageSource()
    page.feed(read_url(canonical))
    if not page.source:
        raise p.Invalid("resolve: Museum Org source view is absent")
    release = json.loads(read_url(config["siteUrl"].rstrip("/") + "/museum-release.json"))
    matches = [n for n in release.get("notes", []) if n.get("href") == href and n.get("status") == "published"]
    if len(matches) != 1:
        raise p.Invalid("resolve: no unique Git source binding for this published page; update stopped, no note created")
    record, published = matches[0], release.get("sourceCommit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", published):
        raise p.Invalid("resolve: invalid published source revision")
    if (page.meta.get("museum-source-commit") != published or
            page.meta.get("museum-note-sha256") != record["sha256"]):
        raise p.Invalid("resolve: page and release are different versions; retry after publication")
    for key, value in (("museum-wiki-id", record["id"]), ("museum-source-path", record["path"])):
        if key in page.meta and page.meta[key] != value:
            raise p.Invalid("resolve: page identity conflicts with its source binding")
    # Do not infer identity from a filename, title, theme query or HTML body.
    path = record["path"]
    target = p.within(root, path)
    if not target.is_file():
        raise p.Invalid("resolve: original Org file is absent locally; update stopped, no note created")
    raw_published = source_blob(root, published, path)
    if hashlib.sha256(raw_published).hexdigest() != record["sha256"]:
        raise p.Invalid("resolve: published source hash does not match Git")
    base = p.git(root, "rev-parse", "HEAD")
    raw = source_blob(root, base, path)
    original = raw.decode("utf-8-sig")
    if p.metadata(original).get("WIKI_ID") != record["id"]:
        raise p.Invalid("resolve: original note identity changed; update stopped")
    if target.read_bytes() != p.blob(root, base, path):
        raise p.Invalid("conflict: target has local edits; update stopped")
    return {"operation": "update", "url": canonical, "href": href, "path": path,
            "wikiId": record["id"], "repository": config["repository"], "baseCommit": base,
            "sourceCommit": published, "sourceSha256": hashlib.sha256(raw).hexdigest(),
            "orgSource": original, "publishedOrgBody": "".join(page.source).replace("\u00a0", " ")}

def protected_material(text):
    # Keep spelling, order, values and repetitions of every existing header except TITLE.
    headers = [line for line in p.prose(text).splitlines()
               if re.match(r"\s*#\+\w+:", line, re.I) and not re.match(r"\s*#\+title:", line, re.I)]
    links = Counter(re.findall(r"\[\[([^]\n]+)\]", text))
    anchors = Counter(re.findall(r"(?im)^\s*:(?:ID|CUSTOM_ID):\s*.+$", text))
    headings = Counter(re.findall(r"(?m)^\*+\s+(.+)$", p.prose(text)))
    # Store whole literal blocks, not only the block-type capture.
    blocks = Counter(match.group(0) for match in re.finditer(r"(?ims)^\s*#\+begin_(src|example|quote)\b[^\n]*\n.*?^\s*#\+end_\1[^\n]*", text))
    return headers, links, anchors, headings, blocks

def validate_update(original, candidate):
    p.privacy(candidate, "updated note")
    before, after = p.metadata(original), p.metadata(candidate)
    if not before.get("WIKI_ID") or after.get("WIKI_ID") != before["WIKI_ID"]:
        raise p.Invalid("update: original wiki_id must be retained")
    protected_before, protected_after = protected_material(original), protected_material(candidate)
    if protected_before[0] != protected_after[0]:
        raise p.Invalid("update: original metadata must be retained verbatim")
    for label, old, new in zip(("references", "anchors", "heading references", "literal blocks"), protected_before[1:], protected_after[1:]):
        if old - new:
            raise p.Invalid(f"update: original {label} must be retained")

def update(root, context, candidate):
    "Commit only the existing selected source; never turn resolution failure into creation."
    root = root.resolve()
    if context.get("operation") != "update":
        raise p.Invalid("update: requires a resolved update operation")
    path = context["path"]
    base_raw = source_blob(root, context["baseCommit"], path)
    if hashlib.sha256(base_raw).hexdigest() != context["sourceSha256"]:
        raise p.Invalid("update: source context is inconsistent")
    original = base_raw.decode("utf-8-sig")
    if p.metadata(original).get("WIKI_ID") != context["wikiId"]:
        raise p.Invalid("update: source identity is inconsistent")
    validate_update(original, candidate)
    with p.sync_lock(root):
        if p.git(root, "branch", "--show-current") != "main" or p.git(root, "diff", "--cached", "--name-only"):
            raise p.Invalid("update: requires main with an empty staging area")
        if p.git(root, "config", "--get", "remote.origin.url").rstrip("/").removesuffix(".git") not in {
                "https://github.com/lovemoganna/org-notes", "git@github.com:lovemoganna/org-notes"}:
            raise p.Invalid("update: unexpected source remote")
        base = p.git(root, "rev-parse", "HEAD")
        target = p.within(root, path)
        if not target.is_file() or target.read_bytes() != p.blob(root, base, path):
            raise p.Invalid("conflict: local target changed; no content overwritten")
        for attempt in range(3):
            p.git(root, "fetch", "origin", "main")
            head = p.git(root, "rev-parse", "origin/main")
            if subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", base, head], capture_output=True).returncode:
                raise p.Invalid("update: local history is ahead or diverged; no commits discarded")
            if source_blob(root, head, path) != base_raw:
                raise p.Invalid("conflict: remote target changed; no content overwritten")
            with tempfile.TemporaryDirectory(prefix="museum-update-") as temporary:
                checkout = Path(temporary) / "checkout"
                p.git(root, "worktree", "add", "--detach", str(checkout), head)
                try:
                    selected = p.within(checkout, path)
                    if not selected.is_file():
                        raise p.Invalid("update: original file is missing; no note created")
                    selected.write_text(candidate, encoding="utf-8", newline="\n")
                    p.validate(checkout)
                    p.git(checkout, "add", "--", path)
                    if p.git(checkout, "diff", "--cached", "--name-only"):
                        p.git(checkout, "commit", "-m", f"Museum-Update: {context['wikiId']}")
                        head = p.git(checkout, "rev-parse", "HEAD")
                        try:
                            p.git(checkout, "push", "origin", f"{head}:refs/heads/main")
                        except p.Invalid as error:
                            if str(error).startswith("retry:") and attempt < 2:
                                continue
                            raise
                    raw = source_blob(root, head, path)
                    if target.read_bytes() != p.blob(root, base, path):
                        raise p.Invalid("conflict: committed remotely; local target changed during push and is preserved")
                    p.reconcile(root, base, head, {})
                    return {"status": "submitted", "operation": "update", "commit": head,
                            "wikiId": context["wikiId"], "path": path, "url": context["url"],
                            "sha256": hashlib.sha256(raw).hexdigest()}
                finally:
                    if checkout.resolve().is_relative_to(Path(temporary).resolve()):
                        p.git(root, "worktree", "remove", "--force", str(checkout))

def github(root, endpoint):
    result = subprocess.run(["gh", "api", endpoint], cwd=root, capture_output=True)
    if result.returncode:
        raise p.Invalid("publication: cannot inspect GitHub Actions")
    return result.stdout.decode("utf-8-sig")

def validate_commit_update(root, base, commit):
    "CI guard for a declared Museum-Update; require exactly one existing Org source."
    changes = p.git(root, "diff", "--name-status", "--no-renames", base, commit).splitlines()
    if len(changes) != 1 or not changes[0].startswith("M\t"):
        raise p.Invalid("update: commit must modify exactly one existing Org source")
    path = changes[0].split("\t", 1)[1]
    validate_update(source_blob(root, base, path).decode("utf-8-sig"), source_blob(root, commit, path).decode("utf-8-sig"))
    return {"status": "valid-update", "path": path, "wikiId": p.metadata(source_blob(root, commit, path).decode("utf-8-sig"))["WIKI_ID"]}

def resolve_cloud(root, url, wait=150):
    "Use the same resolver in Actions when this client's Pages TLS route is unavailable."
    config = json.loads((root / "museum.json").read_text(encoding="utf-8"))
    if config.get("repository") != "lovemoganna/org-notes" or config.get("publishMode") != "actions":
        raise p.Invalid("resolve: authoritative source repository is not configured")
    canonical, _ = canonical_url(url, config["siteUrl"])
    request_id = str(uuid.uuid4())
    dispatch = subprocess.run(["gh", "api", "repos/lovemoganna/org-notes/actions/workflows/resolve-url.yml/dispatches",
                               "--method", "POST", "-f", "ref=main", "-f", f"inputs[page_url]={canonical}",
                               "-f", f"inputs[request_id]={request_id}"], cwd=root, capture_output=True)
    if dispatch.returncode:
        raise p.Invalid("resolve: cloud resolver unavailable; original note not modified")
    deadline = time.monotonic() + min(max(wait, 0), 300)
    while time.monotonic() < deadline:
        runs = json.loads(github(root, "repos/lovemoganna/org-notes/actions/workflows/resolve-url.yml/runs?event=workflow_dispatch&per_page=30"))["workflow_runs"]
        matches = [r for r in runs if r.get("display_title") == "Resolve Museum URL " + request_id]
        if matches and matches[0]["status"] == "completed":
            run = matches[0]
            if run["conclusion"] != "success":
                raise p.Invalid("resolve: cloud resolution failed; inspect " + run["html_url"])
            jobs = json.loads(github(root, f"repos/lovemoganna/org-notes/actions/runs/{run['id']}/jobs"))["jobs"]
            logs = github(root, f"repos/lovemoganna/org-notes/actions/jobs/{jobs[0]['id']}/logs")
            contexts = [json.loads(line.split("MUSEUM-URL-RESOLVED ", 1)[1]) for line in logs.splitlines()
                        if "MUSEUM-URL-RESOLVED {" in line]
            if len(contexts) != 1 or contexts[0].get("url") != canonical or contexts[0].get("operation") != "update":
                raise p.Invalid("resolve: cloud source identity is ambiguous")
            context = contexts[0]
            p.git(root, "fetch", "origin", "main")
            raw = source_blob(root, context["baseCommit"], context["path"])
            if hashlib.sha256(raw).hexdigest() != context["sourceSha256"] or raw.decode("utf-8-sig") != context["orgSource"]:
                raise p.Invalid("resolve: cloud source does not match the Git source")
            context["resolutionBuildUrl"] = run["html_url"]
            return context
        time.sleep(min(10, max(0, deadline - time.monotonic())))
    raise p.Invalid("resolve: cloud resolution still pending; no note modified; request " + request_id)

def publication_status(root, submitted):
    "Keep commit, Actions and verified Pages status separate."
    commit = submitted["commit"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise p.Invalid("publication: invalid commit")
    result = dict(submitted, status="publishing", commitStatus="success", actionsStatus="pending", pagesStatus="pending")
    runs = json.loads(github(root, f"repos/lovemoganna/org-notes/actions/runs?head_sha={commit}&event=push"))["workflow_runs"]
    runs = [run for run in runs if run["path"] == ".github/workflows/publish.yml"]
    if not runs: return result
    run = max(runs, key=lambda r: (r.get("run_attempt", 1), r["id"]))
    result.update(buildUrl=run["html_url"], actionsStatus=run["status"])
    if run["status"] != "completed": return result
    if run["conclusion"] != "success":
        return dict(result, status="publish-failed", actionsStatus=run["conclusion"], pagesStatus="unverified")
    jobs = json.loads(github(root, f"repos/lovemoganna/org-notes/actions/runs/{run['id']}/attempts/{run.get('run_attempt', 1)}/jobs"))["jobs"]
    deploys = [j for j in jobs if j["name"] == "deploy" and j["conclusion"] == "success" and
               any(s["name"] == "Verify live published content" and s["conclusion"] == "success" for s in j["steps"])]
    result.update(actionsStatus="success", pagesStatus="unverified")
    if len(deploys) != 1: return result
    logs = github(root, f"repos/lovemoganna/org-notes/actions/jobs/{deploys[0]['id']}/logs")
    receipts = [json.loads(line.split("MUSEUM-PUBLISHED-RECEIPT ", 1)[1]) for line in logs.splitlines() if "MUSEUM-PUBLISHED-RECEIPT {" in line]
    matches = [r for r in receipts if r.get("sourceCommit") == commit and any(
        n["id"] == submitted["wikiId"] and n["path"] == submitted["path"] and n["sha256"] == submitted["sha256"] and
        n["status"] == "published" for n in r.get("notes", []))]
    if len(matches) == 1:
        result.update(status="updated", pagesStatus="published", verification="post-deployment HTTP attestation")
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["resolve", "update", "status", "check-commit"])
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--url")
    parser.add_argument("--context", type=Path)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--wait", type=int, default=0)
    parser.add_argument("--cloud", action="store_true", help="run URL resolution in the existing read-only Actions workflow")
    parser.add_argument("--base")
    parser.add_argument("--commit")
    args = parser.parse_args()
    try:
        if args.command == "check-commit":
            if not args.base or not args.commit: parser.error("check-commit requires --base and --commit")
            result = validate_commit_update(args.root, args.base, args.commit)
        elif args.command == "resolve":
            if not args.url: parser.error("resolve requires --url")
            if args.cloud:
                result = resolve_cloud(args.root, args.url, args.wait or 150)
            else:
                result = resolve(args.root, args.url)
        else:
            if not args.context: parser.error("update/status requires --context")
            context = json.loads(args.context.read_text(encoding="utf-8-sig"))
            if args.command == "update":
                if not args.candidate: parser.error("update requires --candidate")
                result = update(args.root, context, args.candidate.read_text(encoding="utf-8-sig"))
            else:
                result = publication_status(args.root, context)
            if args.wait:
                if args.output: args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                deadline = time.monotonic() + min(max(args.wait, 0), 300)
                submitted = result
                while time.monotonic() < deadline and result["status"] in {"submitted", "publishing"}:
                    try:
                        result = publication_status(args.root, submitted)
                    except (p.Invalid, OSError, ValueError, KeyError):
                        result = dict(submitted, status="publishing", commitStatus="success", pagesStatus="unverified",
                                      error="publication inspection unavailable; source commit is preserved")
                    if result["status"] in {"updated", "publish-failed"}: break
                    time.sleep(min(15, max(0, deadline - time.monotonic())))
        if args.output: args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False))
    except (p.Invalid, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False))
        raise SystemExit(1)

if __name__ == "__main__": main()
