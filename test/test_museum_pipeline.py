import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

SPEC = importlib.util.spec_from_file_location("pipeline", Path(__file__).parents[1] / "tools/museum_pipeline.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

def note(note_id="note-12345678", extra=""):
    return (f"#+TITLE: 中文笔记\n#+WIKI_ID: {note_id}\n#+CATEGORY: SQL\n"
            f"#+DATE: 2026-10-04\n#+FILETAGS: :sql:\n#+SOURCE: 用户提供\n"
            f"#+INGEST_ID: ingest-12345678\n\n* 问题\n{extra}\n")

class Validation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.path = self.root / "notes/programming/sql/note-12345678.org"
        self.path.parent.mkdir(parents=True)
        self.path.write_text(note(), encoding="utf-8")
    def tearDown(self):
        self.tmp.cleanup()
    def test_valid_and_stable_url(self):
        record = m.validate(self.root)[0]
        self.assertEqual(record["href"], "pages/collected/programming/sql/note-12345678.html")
    def test_missing_header(self):
        self.path.write_text(note().replace("#+SOURCE: 用户提供\n", ""), encoding="utf-8")
        with self.assertRaises(m.Invalid): m.validate(self.root)
    def test_secret_not_disclosed(self):
        secret = "ghp_" + "a" * 36
        with self.assertRaises(m.Invalid) as caught: m.privacy(secret, "note")
        self.assertNotIn(secret, str(caught.exception))
    def test_code_not_interpreted_as_metadata(self):
        self.path.write_text(note(extra="#+begin_src python\nprint('ok')\n#+TITLE: inside code\n#+end_src"), encoding="utf-8")
        self.assertEqual(m.validate(self.root)[0]["title"], "中文笔记")
    def test_unterminated_block(self):
        self.path.write_text(note(extra="#+begin_src python\nprint('ok')"), encoding="utf-8")
        with self.assertRaises(m.Invalid): m.validate(self.root)
    def test_active_export_blocked(self):
        self.path.write_text(note(extra="#+INCLUDE: /private/file"), encoding="utf-8")
        with self.assertRaises(m.Invalid): m.validate(self.root)
    def test_outside_link_blocked(self):
        self.path.write_text(note(extra="[[file:../../../../outside.txt]]"), encoding="utf-8")
        with self.assertRaises(m.Invalid): m.validate(self.root)
    def test_attachments(self):
        asset = self.root / "note-assets/sample.csv"
        asset.parent.mkdir()
        asset.write_text("a,b\n1,2\n", encoding="utf-8")
        self.path.write_text(note(extra="[[file:../../../note-assets/sample.csv]]"), encoding="utf-8")
        self.assertEqual(len(m.validate(self.root)), 1)
    def test_failed_build_no_output(self):
        output = self.root / "output"
        with self.assertRaises(OSError): m.build(self.root, self.root, output, "nonexistent-emacs-123")
        self.assertFalse(output.exists())

class SourceSync(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.parent = Path(self.tmp.name)
        self.remote = self.parent / "remote.git"
        self.root = self.parent / "local"
        self.other = self.parent / "other"
        self.run_git(self.parent, "init", "--bare", str(self.remote))
        self.run_git(self.parent, "init", "-b", "main", str(self.root))
        self.configure(self.root)
        (self.root / "museum.json").write_text(json.dumps({"publishMode": "actions", "repository": "lovemoganna/org-notes"}))
        self.path = self.write(self.root, "note-12345678", "original")
        self.write(self.root, "note-87654321", "second")
        self.commit(self.root)
        self.run_git(self.root, "remote", "add", "origin", "https://github.com/lovemoganna/org-notes.git")
        self.run_git(self.root, "config", f"url.{self.remote.as_posix()}.insteadOf", "https://github.com/lovemoganna/org-notes.git")
        self.run_git(self.root, "push", "-u", "origin", "main")
        self.run_git(self.parent, "clone", "-b", "main", str(self.remote), str(self.other))
        self.configure(self.other)
    def tearDown(self): self.tmp.cleanup()
    def run_git(self, root, *args):
        p = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
        if p.returncode: self.fail(p.stderr.decode("utf-8", "replace"))
        return p.stdout.decode("utf-8").strip()
    def configure(self, root):
        self.run_git(root, "config", "user.name", "Pipeline test")
        self.run_git(root, "config", "user.email", "pipeline@example.invalid")
    def write(self, root, note_id, body):
        path = root / f"notes/programming/sql/{note_id}.org"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(note(note_id, body), encoding="utf-8")
        return path
    def commit(self, root):
        self.run_git(root, "add", ".")
        self.run_git(root, "commit", "-m", "test source change")
    def publish_other(self):
        self.commit(self.other)
        self.run_git(self.other, "push", "origin", "main")
    def test_disjoint_remote_changes_merge_and_repeat_is_idempotent(self):
        self.write(self.root, "note-12345678", "local saved")
        self.write(self.other, "note-87654321", "remote edit")
        self.publish_other()
        result = m.sync(self.root)
        self.assertEqual(result["status"], "submitted")
        self.assertIn("remote edit", (self.root / "notes/programming/sql/note-87654321.org").read_text(encoding="utf-8"))
        self.assertIn("local saved", self.path.read_text(encoding="utf-8"))
        self.assertEqual(self.run_git(self.root, "status", "--porcelain"), "")
        self.assertEqual(m.sync(self.root)["commit"], result["commit"])
    def test_same_file_conflict_preserves_local_bytes_and_head(self):
        self.write(self.root, "note-12345678", "local saved")
        local_bytes = self.path.read_bytes()
        base = self.run_git(self.root, "rev-parse", "HEAD")
        self.write(self.other, "note-12345678", "remote edit")
        self.publish_other()
        with self.assertRaisesRegex(m.Invalid, "conflict"):
            m.sync(self.root)
        self.assertEqual(self.path.read_bytes(), local_bytes)
        self.assertEqual(self.run_git(self.root, "rev-parse", "HEAD"), base)
    def test_remote_only_updates_local_checkout(self):
        self.write(self.other, "note-12345678", "remote edit")
        self.publish_other()
        result = m.sync(self.root)
        self.assertEqual(result["status"], "unchanged")
        self.assertIn("remote edit", self.path.read_text(encoding="utf-8"))
        self.assertEqual(self.run_git(self.root, "status", "--porcelain"), "")
    def test_offline_preserves_pending_then_recovers(self):
        self.write(self.root, "note-12345678", "saved offline")
        self.run_git(self.root, "config", "--unset-all", f"url.{self.remote.as_posix()}.insteadOf")
        # Git transport substitution is the only failure injected; no Git output is mocked.
        self.run_git(self.root, "config", f"url.{(self.parent / 'missing.git').as_posix()}.insteadOf", "https://github.com/lovemoganna/org-notes.git")
        with self.assertRaises(m.Invalid): m.sync(self.root)
        self.assertIn("saved offline", self.path.read_text(encoding="utf-8"))
        self.run_git(self.root, "config", "--unset-all", f"url.{(self.parent / 'missing.git').as_posix()}.insteadOf")
        self.run_git(self.root, "config", f"url.{self.remote.as_posix()}.insteadOf", "https://github.com/lovemoganna/org-notes.git")
        self.assertEqual(m.sync(self.root)["status"], "submitted")
    def test_staged_changes_are_never_consumed(self):
        self.write(self.root, "note-12345678", "staged")
        self.run_git(self.root, "add", ".")
        before = self.run_git(self.root, "diff", "--cached")
        with self.assertRaises(m.Invalid): m.sync(self.root)
        self.assertEqual(self.run_git(self.root, "diff", "--cached"), before)
    def test_push_race_preserves_changes_then_merges_on_retry(self):
        self.write(self.root, "note-12345678", "local saved during race")
        self.write(self.other, "note-87654321", "concurrent remote save")
        self.commit(self.other)
        remote_sha = self.run_git(self.other, "rev-parse", "HEAD")
        base_sha = self.run_git(self.root, "rev-parse", "HEAD")
        # Transfer the real competing commit without advancing main yet.
        self.run_git(self.other, "push", "origin", "HEAD:refs/heads/racing-save")
        hook = self.root / ".git/hooks/pre-push"
        self.run_git(self.root, "config", "core.hooksPath", str(hook.parent))
        hook.write_text("#!/bin/sh\n" +
                        "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE\n" +
                        f"git --git-dir='{self.remote.as_posix()}' update-ref refs/heads/main {remote_sha} {base_sha}\n",
                        encoding="utf-8", newline="\n")
        try:
            with self.assertRaisesRegex(m.Invalid, "retry"):
                m.sync(self.root)
        finally:
            hook.unlink()
        self.assertEqual(self.run_git(self.root, "rev-parse", "HEAD"), base_sha)
        self.assertIn("local saved during race", self.path.read_text(encoding="utf-8"))
        self.assertEqual(m.sync(self.root)["status"], "submitted")
        self.assertIn("concurrent remote save", (self.root / "notes/programming/sql/note-87654321.org").read_text(encoding="utf-8"))

class LiveVerification(unittest.TestCase):
    "Exercise the HTTP boundary, including stale deployment and wrong page bytes."
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.commit = "a" * 40
        self.digest = "b" * 64
        self.href = "pages/collected/knowledge/workflow/note-12345678.html"
        self.receipt = {"sourceCommit": self.commit, "notes": [{
            "id": "note-12345678", "status": "published", "href": self.href,
            "sha256": self.digest}]}
        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(self.root)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.site = f"http://127.0.0.1:{self.server.server_port}/"
        self.write_receipt()
        self.page = self.root / self.href
        self.page.parent.mkdir(parents=True)
        self.page.write_text(f'<meta name="museum-source-commit" content="{self.commit}">'
                             f'<meta name="museum-note-sha256" content="{self.digest}">', encoding="utf-8")
    def write_receipt(self):
        (self.root / "museum-release.json").write_text(json.dumps(self.receipt), encoding="utf-8")
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()
    def test_current_page_returns_verified_receipt(self):
        receipt = m.verify_live(self.site, self.commit, attempts=1, interval=0)
        self.assertEqual(receipt["status"], "published")
        self.assertEqual(receipt["siteUrl"], self.site)
    def test_stale_release_times_out_without_success(self):
        self.receipt["sourceCommit"] = "c" * 40
        self.write_receipt()
        with self.assertRaisesRegex(m.Invalid, "could not be confirmed"):
            m.verify_live(self.site, self.commit, attempts=1, interval=0)
    def test_wrong_content_hash_is_not_published(self):
        self.page.write_text(f'<meta name="museum-source-commit" content="{self.commit}">'
                             f'<meta name="museum-note-sha256" content="{"c" * 64}">', encoding="utf-8")
        with self.assertRaisesRegex(m.Invalid, "could not be confirmed"):
            m.verify_live(self.site, self.commit, attempts=1, interval=0)
    def test_missing_page_is_not_published(self):
        self.page.unlink()
        with self.assertRaisesRegex(m.Invalid, "could not be confirmed"):
            m.verify_live(self.site, self.commit, attempts=1, interval=0)

if __name__ == "__main__": unittest.main()
