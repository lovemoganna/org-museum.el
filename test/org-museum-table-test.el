;;; org-museum-table-test.el --- Native table cell breaks -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)

(ert-deftest org-museum-table-cell-native-breaks ()
  "All allowed break snippets render within a single native Org cell."
  (dolist (br '("<br>" "<br/>" "<br />"))
    (let ((html (org-export-string-as
                 (format "| 项目 | 说明 |\n|------+------|\n| *步骤* | 第一行@@html:%s@@第二行@@html:%s@@[[https://example.org][第三行]] |\n" br br)
                 'org-museum-html t)))
      (should (= 2 (org-museum-table-test--count "<td\\b" html)))
      (should (= 2 (org-museum-table-test--count "<br\\(?: /\\|/\\)?>" html)))
      (should (string-search "<b>步骤</b>" html))
      (should (string-search "href=\"https://example.org\"" html))
      (should-not (string-search "@@html:" html)))))

(defun org-museum-table-test--count (regexp string)
  (let ((count 0) (start 0))
    (while (string-match regexp string start)
      (setq count (1+ count) start (match-end 0)))
    count))

(ert-deftest org-museum-table-break-code-remains-literal ()
  "Native export must not interpret break snippets inside code examples."
  (let ((html (org-export-string-as
               "#+begin_example\n| 示例 | 第一行@@html:<br>@@第二行 |\n#+end_example\n"
               'org-museum-html t)))
    (should (string-search "@@html:&lt;br&gt;@@" html))
    (should-not (string-search "<br>" html))))

(ert-deftest org-museum-table-ordinary-rows-unchanged ()
  (let ((html (org-export-string-as
               "| 项目 | 说明 |\n|------+------|\n| 普通 | A & B |\n| 第二项 | 保留行结构 |\n"
               'org-museum-html t)))
    (should (= 4 (org-museum-table-test--count "<td\\b" html)))
    (should (string-search "A &amp; B" html))
    (should-not (string-match-p "<br\\b" html))))
