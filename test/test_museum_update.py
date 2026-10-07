import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).parents[1] / "tools"))
import museum_update as u

ORIGINAL = '''#+title: 求和函数
#+WIKI_ID: historical-id
#+CATEGORY: Python
#+FILETAGS: :python:
#+DATE: 2026-10-04
#+SOURCE: 用户提供，原始出处未提供
#+INGEST_ID: original-ingest
#+OPTIONS: toc:nil

* 使用
把求和封装成函数。
#+begin_src python
def total(values):
    return sum(values)
#+end_src
[[https://www.python.org/][Python]]

* 验证
尚未运行。
'''
CANDIDATE = ORIGINAL.replace("把求和封装成函数。", "需要复用求和操作时，把它封装成函数。")

class Preservation(unittest.TestCase):
    def test_update_retains_legacy_headers_without_inventing_missing_fields(self):
        old = ORIGINAL.replace("#+DATE: 2026-10-04\n", "").replace("#+INGEST_ID: original-ingest\n", "")
        u.validate_update(old, old.replace("把求和封装成函数。", "把可复用的求和操作封装成函数。"))
    def test_identity_change_is_rejected(self):
        with self.assertRaisesRegex(u.p.Invalid, "wiki_id"):
            u.validate_update(ORIGINAL, CANDIDATE.replace("historical-id", "new-note-id"))
    def test_metadata_removal_is_rejected(self):
        with self.assertRaisesRegex(u.p.Invalid, "metadata"):
            u.validate_update(ORIGINAL, CANDIDATE.replace("#+OPTIONS: toc:nil\n", ""))
    def test_reference_removal_is_rejected(self):
        with self.assertRaisesRegex(u.p.Invalid, "references"):
            u.validate_update(ORIGINAL, CANDIDATE.replace("[[https://www.python.org/][Python]]", ""))
    def test_literal_code_change_is_rejected(self):
        with self.assertRaisesRegex(u.p.Invalid, "literal blocks"):
            u.validate_update(ORIGINAL, CANDIDATE.replace("return sum(values)", "return 0"))
    def test_heading_rename_is_rejected_for_incoming_reference_compatibility(self):
        with self.assertRaisesRegex(u.p.Invalid, "heading references"):
            u.validate_update(ORIGINAL, CANDIDATE.replace("* 验证", "* 实测"))
    def test_query_and_fragment_do_not_change_identity(self):
        site = "https://lovemoganna.github.io/org-notes/"
        page = site + "pages/collected/programming/python/historical-id.html"
        self.assertEqual(u.canonical_url(page, site), u.canonical_url(page + "?theme=dark&source=chat#使用", site))
    def test_external_url_and_traversal_are_rejected(self):
        site = "https://lovemoganna.github.io/org-notes/"
        for url in ("https://example.com/org-notes/pages/x.html", site + "pages/%2e%2e/x.html", site + "pages/%252e%252e/x.html"):
            with self.subTest(url=url), self.assertRaises(u.p.Invalid): u.canonical_url(url, site)

class UrlUpdate(unittest.TestCase):
    def git(self, root, *args):
        result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
        if result.returncode: self.fail(result.stderr.decode("utf-8", "replace"))
        return result.stdout.decode("utf-8").strip()
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.parent = Path(self.tmp.name)
        self.root = self.parent / "repo"
        self.root.mkdir()
        self.remote = self.parent / "remote.git"
        self.git(self.parent, "init", "--bare", str(self.remote))
        self.git(self.root, "init", "-b", "main")
        self.git(self.root, "config", "user.name", "Museum update test")
        self.git(self.root, "config", "user.email", "update@example.invalid")
        self.git(self.root, "config", "core.autocrlf", "false")
        self.path = "notes/programming/python/historical-id.org"
        self.note = self.root / self.path
        self.note.parent.mkdir(parents=True)
        self.note.write_text(ORIGINAL, encoding="utf-8", newline="\n")
        self.web = self.parent / "web"
        self.web.mkdir()
        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(self.web)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.site = f"http://127.0.0.1:{self.server.server_port}/"
        (self.root / "museum.json").write_text(json.dumps({"siteUrl": self.site, "repository": "lovemoganna/org-notes", "publishMode": "actions"}), encoding="utf-8")
        self.git(self.root, "add", ".")
        self.git(self.root, "commit", "-m", "original source")
        self.commit = self.git(self.root, "rev-parse", "HEAD")
        self.git(self.root, "remote", "add", "origin", "https://github.com/lovemoganna/org-notes.git")
        self.git(self.root, "config", f"url.{self.remote.as_posix()}.insteadOf", "https://github.com/lovemoganna/org-notes.git")
        self.git(self.root, "push", "-u", "origin", "main")
        self.href = "pages/collected/programming/python/historical-id.html"
        self.hash = hashlib.sha256(self.note.read_bytes()).hexdigest()
        self.receipt = {"sourceCommit": self.commit, "notes": [{"id": "historical-id", "path": self.path, "href": self.href, "sha256": self.hash, "status": "published"}]}
        self.save_receipt()
        self.page = self.web / self.href
        self.page.parent.mkdir(parents=True)
        self.page.write_text(f'<meta name="museum-source-commit" content="{self.commit}">'
                             f'<meta name="museum-note-sha256" content="{self.hash}">'
                             '<pre class="museum-org-source"><code><span>* 使用</span>\n过滤后的正文</code></pre>', encoding="utf-8")
        self.url = self.site + self.href + "?theme=dark&source=chat#使用"
    def save_receipt(self):
        (self.web / "museum-release.json").write_text(json.dumps(self.receipt), encoding="utf-8")
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()
    def test_resolves_complete_git_source_instead_of_filtered_html(self):
        result = u.resolve(self.root, self.url)
        self.assertEqual(result["operation"], "update")
        self.assertEqual(result["orgSource"], ORIGINAL)
        self.assertNotEqual(result["orgSource"], result["publishedOrgBody"])
        self.assertEqual(result["path"], self.path)
    def test_unbound_historical_page_stops_without_creating_note(self):
        self.receipt["notes"] = []
        self.save_receipt()
        with self.assertRaisesRegex(u.p.Invalid, "no unique Git source"):
            u.resolve(self.root, self.url)
        self.assertEqual(self.git(self.root, "status", "--porcelain"), "")
    def test_missing_source_stops_without_creating_note(self):
        self.note.unlink()
        with self.assertRaisesRegex(u.p.Invalid, "absent locally"):
            u.resolve(self.root, self.url)
        self.assertFalse(self.note.exists())
    def test_stale_page_is_rejected(self):
        self.page.write_text('<pre class="museum-org-source"><code>正文</code></pre>', encoding="utf-8")
        with self.assertRaisesRegex(u.p.Invalid, "different versions"):
            u.resolve(self.root, self.url)
    def test_original_source_link_cannot_select_a_different_note(self):
        self.page.write_text(self.page.read_text(encoding="utf-8") +
                             '<link rel="alternate" type="text/org" href="https://example.com/other.org">', encoding="utf-8")
        with self.assertRaisesRegex(u.p.Invalid, "source URL conflicts"):
            u.resolve(self.root, self.url)
    def test_in_place_commit_and_repeat_keep_identity_and_path(self):
        context = u.resolve(self.root, self.url)
        result = u.update(self.root, context, CANDIDATE)
        self.assertEqual(result["operation"], "update")
        self.assertEqual(result["path"], self.path)
        self.assertEqual(result["wikiId"], "historical-id")
        self.assertEqual(self.git(self.root, "diff", "--name-only", self.commit, result["commit"]), self.path)
        self.assertEqual(self.note.read_text(encoding="utf-8"), CANDIDATE)
        self.assertEqual(u.validate_commit_update(self.root, self.commit, result["commit"])["path"], self.path)
        # Resolve from the new source revision; the published view may still be old.
        retry = u.resolve(self.root, self.url)
        self.assertEqual(u.update(self.root, retry, CANDIDATE)["commit"], result["commit"])
    def test_remote_same_file_conflict_preserves_local_source(self):
        context = u.resolve(self.root, self.url)
        other = self.parent / "other"
        self.git(self.parent, "clone", "-b", "main", str(self.remote), str(other))
        self.git(other, "config", "user.name", "Concurrent editor")
        self.git(other, "config", "user.email", "other@example.invalid")
        (other / self.path).write_text(ORIGINAL + "\n并发修改\n", encoding="utf-8")
        self.git(other, "add", self.path)
        self.git(other, "commit", "-m", "concurrent edit")
        self.git(other, "push", "origin", "main")
        with self.assertRaisesRegex(u.p.Invalid, "remote target changed"):
            u.update(self.root, context, CANDIDATE)
        self.assertEqual(self.note.read_text(encoding="utf-8"), ORIGINAL)
        self.assertEqual(self.git(self.root, "rev-parse", "HEAD"), self.commit)
    def test_update_commit_cannot_create_duplicate_source(self):
        duplicate = self.note.with_name("duplicate-note.org")
        duplicate.write_text(ORIGINAL, encoding="utf-8")
        self.git(self.root, "add", ".")
        self.git(self.root, "commit", "-m", "Museum-Update: historical-id")
        with self.assertRaisesRegex(u.p.Invalid, "exactly one existing"):
            u.validate_commit_update(self.root, self.commit, self.git(self.root, "rev-parse", "HEAD"))

if __name__ == "__main__": unittest.main()
