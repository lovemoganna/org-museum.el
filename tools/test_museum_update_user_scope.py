#!/usr/bin/env python3
"""User-directed published note removals: allowed scope versus protected material."""
import unittest
import museum_update as m
from museum_pipeline import Invalid

META = """#+TITLE: 原文
#+WIKI_ID: 7fbbd925-3040-46ec-8f86-4cad706eb8ad
#+CATEGORY: 知识
#+FILETAGS: :knowledge:
#+DATE: 2026-10-18
#+SOURCE: user supplied
#+INGEST_ID: ec05a9dd-e3f5-4bcd-9cc2-a93c840ba290
#+WIKI_STATUS: published

"""
BEFORE = META + """* 主题
[[https://example.org/good][必要来源]]
** 无关部分
[[https://example.org/bad][无关来源]]
* 结论
必要文字。
"""
AFTER = META + """* 主题
[[https://example.org/good][必要来源]]
* 结论
必要文字。
"""
SCOPE = {"user_directive": "移除与文章主题无关的部分",
         "heading references": ["无关部分"],
         "references": ["https://example.org/bad"]}

class Tests(unittest.TestCase):
    def test_no_deletion_without_explicit_scope(self):
        with self.assertRaises(Invalid): m.validate_update(BEFORE, AFTER)
    def test_user_scoped_deletion(self):
        m.validate_update(BEFORE, AFTER, SCOPE)
    def test_missing_link_declaration(self):
        with self.assertRaises(Invalid):
            m.validate_update(BEFORE, AFTER, {"user_directive":"删除主题", "heading references":["无关部分"]})
    def test_unrelated_link_missing(self):
        with self.assertRaises(Invalid):
            m.validate_update(BEFORE, AFTER.replace("[[https://example.org/good][必要来源]]", ""), SCOPE)
    def test_wrong_title_declaration(self):
        with self.assertRaises(Invalid):
            m.validate_update(BEFORE, AFTER, {**SCOPE, "heading references": ["其他部分"]})
    def test_empty_directive(self):
        with self.assertRaises(Invalid):
            m.validate_update(BEFORE, AFTER, {**SCOPE, "user_directive": ""})
    def test_unknown_scope_key(self):
        with self.assertRaises(Invalid):
            m.validate_update(BEFORE, AFTER, {**SCOPE, "allow_all": True})
    def test_identity_change(self):
        with self.assertRaises(Invalid):
            m.validate_update(BEFORE, AFTER.replace("7fbbd925-3040-46ec-8f86-4cad706eb8ad", "00000000-0000-4000-8000-000000000000"), SCOPE)
    def test_metadata_change(self):
        with self.assertRaises(Invalid):
            m.validate_update(BEFORE, AFTER.replace("#+DATE: 2026-10-18", "#+DATE: 2026-10-19"), SCOPE)
    def test_new_image_presentation_attribute_allowed(self):
        image = "#+ATTR_HTML: :alt Cover :width 100%\\n[[file:../../../note-assets/example/cover.webp]]\\n"
        m.validate_update(BEFORE, BEFORE.replace("* 主题", image+"* 主题"))

    def test_existing_image_attribute_cannot_change(self):
        original = BEFORE.replace("* 主题", "#+ATTR_HTML: :width 100%\\n* 主题")
        changed = original.replace("#+ATTR_HTML: :width 100%", "#+ATTR_HTML: :width 50%")
        with self.assertRaises(Invalid):
            m.validate_update(original, changed)

    def test_addition_still_allowed(self):
        m.validate_update(BEFORE, BEFORE + "\n* 新增\n已核对。\n")

if __name__ == "__main__":
    unittest.main()
