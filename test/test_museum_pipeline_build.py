"""Run with MUSEUM_TEST_LEGACY pointing to a real legacy org-notes checkout."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ENGINE = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("pipeline", ENGINE / "tools/museum_pipeline.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

class LegacyAssets(unittest.TestCase):
    def test_export_cleanup_cannot_remove_preserved_page_assets(self):
        with tempfile.TemporaryDirectory(prefix="museum-legacy-assets-") as temporary:
            root = Path(temporary) / "repo"
            (root / "assets").mkdir(parents=True)
            (root / "assets/legacy.png").write_bytes(b"published legacy image")
            (root / "museum.json").write_text(json.dumps({"repository": "owner/site"}))
            output = Path(temporary) / "site"

            def export(_args, **kwargs):
                candidate = Path(kwargs["env"]["MUSEUM_OUTPUT"])
                # The source-only export registry does not know legacy images.
                (candidate / "assets/legacy.png").unlink()
                return subprocess.CompletedProcess(_args, 0, b"", b"")

            with patch.object(m, "validate", return_value=[]), \
                 patch.object(m, "legacy_records", return_value=[]), \
                 patch.object(m, "check_site"), \
                 patch.object(m, "git", return_value="a" * 40), \
                 patch.object(m.subprocess, "run", side_effect=export):
                m.build(root, ENGINE, output, "test-emacs")
            self.assertEqual((output / "assets/legacy.png").read_bytes(),
                             (root / "assets/legacy.png").read_bytes())

@unittest.skipUnless(os.getenv("MUSEUM_TEST_LEGACY"), "real legacy checkout required")
class BatchBuild(unittest.TestCase):
    def test_real_merge_attachments_chinese_and_no_babel(self):
        with tempfile.TemporaryDirectory(prefix="museum-e2e-") as temporary:
            root = Path(temporary) / "repo"
            subprocess.run(["git", "clone", "--shared", os.environ["MUSEUM_TEST_LEGACY"], str(root)], check=True, capture_output=True)
            note = root / "notes/programming/python/note-e2e12345.org"
            note.parent.mkdir(parents=True, exist_ok=True)
            marker = Path(temporary) / "EXECUTED"
            os.environ["MUSEUM_PROBE"] = str(marker)
            try:
                note.write_text('''#+TITLE: 中文标题：导出不能执行代码
#+WIKI_ID: note-e2e12345
#+CATEGORY: Python
#+FILETAGS: :python:org:
#+DATE: 2026-10-04
#+SOURCE: 自动化回归测试
#+INGEST_ID: ingest-e2e12345

* 未验证的程序
#+name: never-run
#+begin_src emacs-lisp :eval yes
(write-region "bad" nil (getenv "MUSEUM_PROBE"))
#+end_src
#+CALL: never-run()

[[file:../../../note-assets/sample.csv][必要附件]]
''', encoding="utf-8")
                asset = root / "note-assets/sample.csv"
                asset.parent.mkdir(exist_ok=True)
                asset.write_text("id,value\n1,2\n", encoding="utf-8")
                output = Path(temporary) / "site"
                receipt = m.build(root, ENGINE, output, os.getenv("MUSEUM_TEST_EMACS", "emacs"))
                self.assertFalse(marker.exists(), "Babel must never execute")
                record = next(r for r in receipt["notes"] if r["id"] == "note-e2e12345")
                page = output / record["href"]
                self.assertTrue(page.is_file())
                self.assertIn('type="text/org"', page.read_text(encoding="utf-8"))
                self.assertIn(record["sourceUrl"], page.read_text(encoding="utf-8"))
                self.assertIn("note-e2e12345", (output / "resources/org-museum-related-data.js").read_text(encoding="utf-8"))
                self.assertGreater(receipt["legacyPages"], 0)
                for old in (root / "pages").rglob("*.html"):
                    self.assertEqual(old.read_bytes(), (output / old.relative_to(root)).read_bytes())
                self.assertFalse((output / "notes").exists())
            finally:
                os.environ.pop("MUSEUM_PROBE", None)

if __name__ == "__main__": unittest.main()
