;;; org-museum-context-test.el --- Local context graph tests -*- lexical-binding: t -*-

(require 'ert)
(setq load-prefer-newer t)
(require 'org-museum)

(defmacro org-museum-context-test--with-wiki (&rest body)
  `(let* ((org-museum-root-dir (make-temp-file "org-museum-context-" t))
          (org-museum-knowledge--root nil)
          (org-museum-knowledge--queue nil)
          (org-museum-knowledge--analyses nil)
          (org-museum-knowledge--experiences nil)
          (org-museum-knowledge--relations nil)
          (org-museum--index nil))
     (unwind-protect (progn ,@body)
       (delete-directory org-museum-root-dir t))))

(defun org-museum-context-test--ids (data)
  (mapcar (lambda (node) (alist-get 'id node))
          (plist-get data :nodes)))

(ert-deftest org-museum-context-analysis-hides-markdown-source-markers ()
  (let ((result (org-museum-context--readable-markdown
                 "## 核心要点\n\n- **重点**与 `code`\n\n> 引用\n\n| 字段 | 值 |\n|---|---|\n| a | b |\n\n```sql\nSELECT 1;\n```")))
    (should (string-match-p "核心要点" result))
    (should (string-match-p "重点.*code" result))
    (should (string-match-p "SELECT 1;" result))
    (should (string-match-p "字段.*值" result))
    (should-not (string-match-p "##\\|\\*\\*\\|```\\||---|" result))))

(ert-deftest org-museum-context-graph-stays-local-and-expands-one-hop ()
  (org-museum-context-test--with-wiki
   (let* ((a (expand-file-name "a.org" org-museum-root-dir))
          (b (expand-file-name "b.org" org-museum-root-dir))
          (c (expand-file-name "c.org" org-museum-root-dir))
          (d (expand-file-name "d.org" org-museum-root-dir))
          (page-a (make-org-museum-page :id "a" :path a
                                         :title "SQLite timeout guide"
                                         :links-to '("b")))
          (page-b (make-org-museum-page :id "b" :path b
                                         :title "Retry case"
                                         :links-to '("c")))
          (page-c (make-org-museum-page :id "c" :path c :title "Second hop"))
          (page-d (make-org-museum-page :id "d" :path d :title "Unrelated"))
          (pages (make-hash-table :test 'equal)))
     (with-temp-file a (insert "#+TITLE: SQLite timeout guide\n* Tutorial\nBody.\n"))
     (with-temp-file b (insert "#+TITLE: Retry case\n"))
     (with-temp-file c (insert "#+TITLE: Second hop\n"))
     (with-temp-file d (insert "#+TITLE: Unrelated\n"))
     (dolist (pair `(("a" . ,page-a) ("b" . ,page-b)
                     ("c" . ,page-c) ("d" . ,page-d)))
       (puthash (car pair) (cdr pair) pages))
     (setq org-museum--index (make-org-museum-index :pages pages))
     (org-museum-knowledge--ensure)
     (setq org-museum-knowledge--experiences
           `(((id . "first") (file . ,a) (pageId . "a")
              (sourceHash . ,(org-museum-knowledge--file-hash a))
              (problem . "SQLite timeout") (result . "Set busy timeout")
              (wrongAttempt . "Retried immediately")
              (evidence . ((line . 3) (excerpt . "Private execution evidence")))
              (verification . "user-confirmed") (published . t))
             ((id . "second") (file . ,b) (pageId . "b")
              (sourceHash . ,(org-museum-knowledge--file-hash b))
              (problem . "Retry case") (result . "Back off")
              (published . t))))
     (setq org-museum-knowledge--analyses
           `(((file . ,a) (hash . ,(org-museum-knowledge--file-hash a))
              (summary . "Unverified summary") (model . "local"))))
     (setq org-museum-knowledge--relations
           `(((sourcePageId . "a") (targetPageId . "b")
              (sourceFile . ,a) (targetFile . ,b)
              (sourceHash . ,(org-museum-knowledge--file-hash a))
              (targetHash . ,(org-museum-knowledge--file-hash b))
              (type . "depends-on") (label . "前置依赖")
              (confidence . 0.9) (origin . "user-confirmed"))))
     (let* ((one (org-museum-context--data
                  page-a "SQLite timeout" 1 '("Tutorial" 2)))
            (two (org-museum-context--data
                  page-a "SQLite timeout" 2 '("Tutorial" 2)))
            (tutorial (org-museum-context--data
                       page-a nil 1 '("Tutorial" 2)))
            (one-ids (org-museum-context-test--ids one))
            (two-ids (org-museum-context-test--ids two)))
       (dolist (id '("a" "b" "context:task" "context:section"
                      "context:analysis" "experience:first"))
         (should (member id one-ids)))
       (should-not (member "c" one-ids))
       (should-not (member "d" two-ids))
       (should (member "c" two-ids))
       (should (member "experience:second" two-ids))
       (should (member "context:section"
                       (org-museum-context-test--ids tutorial)))
       (should-not (member "context:task"
                           (org-museum-context-test--ids tutorial)))
       (should (<= (length one-ids) 7))
       (should (imagep (org-museum-context--svg one))))
     (let ((org-museum-context-max-first-hop-pages 2)
           (org-museum-context-max-pages 3))
       (should-not (member "c" (org-museum-context-test--ids
                                 (org-museum-context--data
                                  page-a "SQLite timeout" 1))))
       (should (member "c" (org-museum-context-test--ids
                            (org-museum-context--data
                             page-a "SQLite timeout" 2)))))
     (with-temp-buffer
       (insert-file-contents a)
       (setq buffer-file-name a)
       (org-mode)
       (set-buffer-modified-p nil)
       (search-forward "Tutorial")
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (&rest _) (ert-fail "context graph called AI"))))
         (org-museum-context-graph "SQLite timeout")))
     (with-current-buffer "*Org Museum 上下文图谱*"
       (should (eq major-mode 'org-museum-context-graph-mode))
       (should (eq (lookup-key org-museum-context-graph-mode-map (kbd "x"))
                   #'org-museum-context-expand))
       (should (eq (lookup-key org-museum-mode-map (kbd "C-c w G"))
                   #'org-museum-context-graph))
       (should (= 1 org-museum-context--depth))
       (should (string-match-p "当前上下文" (buffer-string)))
       (org-museum-context-next-node)
       (should-not (equal "a" org-museum-context--selected-id))
       (org-museum-context-previous-node)
       (should (equal "a" org-museum-context--selected-id))
       (setq org-museum-context--selected-id "experience:first")
       (org-museum-context--render)
       (should-not (string-match-p "Private execution evidence" (buffer-string)))
       (org-museum-context-toggle-evidence)
       (should (looking-at-p "\n所选节点"))
       (should (string-match-p "Retried immediately" (buffer-string)))
       (should (string-match-p "Private execution evidence" (buffer-string)))
       (let (opened)
         (cl-letf (((symbol-function 'find-file-other-window)
                    (lambda (file) (setq opened file))))
           (org-museum-context-open-source))
         (should (equal a opened)))
       (org-museum-context-expand)
       (should (= 2 org-museum-context--depth))
       (should (member "c" (org-museum-context-test--ids
                             org-museum-context--data)))
       (org-museum-context-collapse)
       (should (= 1 org-museum-context--depth)))
     (with-temp-buffer
       (org-museum-context-graph "SQLite timeout"))
     (with-current-buffer "*Org Museum 上下文图谱*"
       (should (equal "a" org-museum-context--anchor-id)))
     (with-temp-buffer
       (org-museum-context-graph "Back off"))
     (with-current-buffer "*Org Museum 上下文图谱*"
       (should (equal "b" org-museum-context--anchor-id)))
     (with-temp-file b (insert "#+TITLE: Changed\n"))
     (let ((after (org-museum-context--data page-a "SQLite timeout" 1)))
       (should-not (member "experience:second"
                           (org-museum-context-test--ids after)))))))

(provide 'org-museum-context-test)
;;; org-museum-context-test.el ends here
