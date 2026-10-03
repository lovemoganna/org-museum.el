;;; org-museum-derived-test.el --- Derived knowledge regression -*- lexical-binding: t -*-

(require 'ert)
(setq load-prefer-newer t)
(require 'org-museum)

(defmacro org-museum-derived-test--with-wiki (&rest body)
  `(let* ((org-museum-root-dir (make-temp-file "org-museum-derived-" t))
          (org-museum-knowledge--root nil)
          (org-museum-knowledge--queue nil)
          (org-museum-knowledge--analyses nil)
          (org-museum-knowledge--experiences nil)
          (org-museum-knowledge--relations nil)
          (org-museum-derived--root nil)
          (org-museum-derived--items nil)
          (org-museum-derived--active nil)
          (org-museum-derived--request-buffer nil)
          (org-museum--index nil))
     (unwind-protect (progn ,@body)
       (delete-directory org-museum-root-dir t))))

(ert-deftest org-museum-derived-gptel-reasoning-keeps-request-active ()
  (org-museum-derived-test--with-wiki
   (let* ((request '((id . "derive") (task . "Combine methods")
                     (sources . (((title . "A") (excerpt . "VALUES"))
                                 ((title . "B") (excerpt . "EXCEPT ALL"))))))
          callback completed)
     (setq org-museum-derived--active request)
     (cl-letf (((symbol-function 'org-museum-knowledge--backend)
                (lambda () 'local-backend))
               ((symbol-function 'gptel-request)
                (lambda (_prompt &rest args)
                  (setq callback (plist-get args :callback))))
               ((symbol-function 'org-museum-derived--finish)
                (lambda (actual response _status)
                  (setq completed (list actual response)))))
       (org-museum-derived--request request)
       (funcall callback '(reasoning . "thinking")
                '(:status "HTTP/1.1 200 OK"))
       (should-not completed)
       (funcall callback "{\"claim\":\"Combined\"}"
                '(:status "HTTP/1.1 200 OK"))
       (should (eq (car completed) org-museum-derived--active)))
     (when (buffer-live-p org-museum-derived--request-buffer)
       (kill-buffer org-museum-derived--request-buffer)))))

(ert-deftest org-museum-derived-combination-needs-review-and-current-sources ()
  (org-museum-derived-test--with-wiki
   (let* ((file-a (expand-file-name "method.org" org-museum-root-dir))
          (file-b (expand-file-name "evidence.org" org-museum-root-dir))
          (file-result (expand-file-name "result.org" org-museum-root-dir))
          (page-a (make-org-museum-page
                   :id "method" :path file-a :title "Method"
                   :links-to '("evidence")))
          (page-b (make-org-museum-page
                   :id "evidence" :path file-b :title "Evidence"))
          (pages (make-hash-table :test 'equal))
          (model-calls 0))
     (with-temp-file file-a
       (insert "#+TITLE: Method\nUse VALUES to construct expected rows.\n"))
     (with-temp-file file-b
       (insert "#+TITLE: Evidence\nEXCEPT ALL preserves duplicate counts.\n"))
     (with-temp-file file-result
       (insert "#+TITLE: Result\n#+RESULTS:\n: 0 mismatched rows\n"))
     (puthash "method" page-a pages)
     (puthash "evidence" page-b pages)
     (setq org-museum--index (make-org-museum-index :pages pages))
     (with-temp-buffer
       (insert-file-contents file-a)
       (setq buffer-file-name file-a)
       (org-mode)
       (set-buffer-modified-p nil)
       (cl-letf (((symbol-function 'org-museum-derived--preflight)
                  (lambda (_request) (cl-incf model-calls))))
         (org-museum-derive-current
          "Check exact rows including duplicates" "evidence")))
     (should (= model-calls 1))
     (let* ((request org-museum-derived--active)
            (sources (alist-get 'sources request)))
       (should (= 2 (length sources)))
       (should (string-match-p "VALUES" (alist-get 'excerpt (car sources))))
       (should (string-match-p "EXCEPT ALL" (alist-get 'excerpt (cadr sources))))
       (should (equal (alist-get 'hash (car sources))
                      (org-museum-knowledge--file-hash file-a)))
       (should-error (org-museum-derived--response-json "not JSON"))
       (org-museum-derived--finish
        request
        "```json\n{\"claim\":\"Use VALUES with EXCEPT ALL to check exact rows\",\"why\":\"One builds expected rows and the other counts duplicates\",\"verification_plan\":\"Execute both differences and check zero rows\"}\n```"
        nil))
     (let* ((item (car org-museum-derived--items))
            (id (alist-get 'id item)))
       (should (equal "ai-inference" (alist-get 'status item)))
       (should-not (string-match-p
                    "Use VALUES with EXCEPT ALL"
                    (or (org-museum-knowledge--page-html page-a) "")))
       (should (string-empty-p
                (org-museum-derived--recall-text "exact rows" "method")))
       (should-not (seq-find (lambda (node)
                               (eq (alist-get 'kind node) 'derived))
                             (plist-get (org-museum-context--data
                                         page-a "exact rows" 1) :nodes)))
       (with-current-buffer "*Org Museum 派生知识*"
         (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
           (org-museum-derived-accept)))
       (should (equal "ai-inference" (alist-get 'status item)))
       (with-current-buffer "*Org Museum 派生知识*"
         (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
           (org-museum-derived-accept)))
       (should (equal "user-confirmed" (alist-get 'status item)))
       (should-not (string-match-p
                    "Use VALUES with EXCEPT ALL"
                    (or (org-museum-knowledge--page-html page-a) "")))
       (should (string-match-p "Use VALUES with EXCEPT ALL"
                               (org-museum-derived--recall-text
                                "exact rows" "method")))
       (with-temp-buffer
         (org-museum-recall "exact rows"))
       (with-current-buffer "*Org Museum 知识上下文*"
         (should (string-match-p "已确认派生知识" (buffer-string)))
         (should-not (string-match-p "没有找到相关" (buffer-string))))
       (should (seq-find (lambda (node)
                           (eq (alist-get 'kind node) 'derived))
                         (plist-get (org-museum-context--data
                                     page-a "exact rows" 1) :nodes)))
       (should (equal 'org-museum-derive-current
                      (lookup-key org-museum-mode-map (kbd "C-c w D"))))
       (should (file-exists-p (org-museum-derived--path)))
       (setq org-museum-derived--root nil
             org-museum-derived--items nil)
       (org-museum-derived--ensure)
       (should (= 1 (length org-museum-derived--items)))
       (should (equal id (alist-get 'id (car org-museum-derived--items))))
       (with-temp-file file-a
         (insert "#+TITLE: Changed Method\n"))
       (should-not (org-museum-derived--confirmed-p
                    (car org-museum-derived--items)))
       (should (string-empty-p
                (org-museum-derived--recall-text "exact rows" "method")))
       (should-error (org-museum-derived-accept) :type 'user-error)))))

(ert-deftest org-museum-derived-verification-requires-recorded-result ()
  (org-museum-derived-test--with-wiki
   (let* ((a (expand-file-name "a.org" org-museum-root-dir))
          (b (expand-file-name "b.org" org-museum-root-dir))
          (result (expand-file-name "result.org" org-museum-root-dir)))
     (with-temp-file a (insert "#+TITLE: A\nVALUES makes expected rows.\n"))
     (with-temp-file b (insert "#+TITLE: B\nEXCEPT ALL preserves duplicates.\n"))
     (with-temp-file result
       (insert "#+TITLE: Result\n#+RESULTS:\n: 0 rows\n"))
     (org-museum-derived--ensure)
     (let ((item `((id . "derived-test")
                   (task . "Compare exact rows")
                   (claim . "Use VALUES plus EXCEPT ALL")
                   (why . "Expected rows and duplicate comparison")
                   (verificationPlan . "Check zero unmatched rows")
                   (status . "user-confirmed")
                   (sources . (((pageId . "a") (title . "A")
                                (file . ,a)
                                (hash . ,(org-museum-knowledge--file-hash a))
                                (line . 1) (excerpt . "VALUES"))
                               ((pageId . "b") (title . "B")
                                (file . ,b)
                                (hash . ,(org-museum-knowledge--file-hash b))
                                (line . 1) (excerpt . "EXCEPT ALL")))))))
       (setq org-museum-derived--items (list item))
       (with-temp-buffer
         (insert-file-contents result)
         (setq buffer-file-name result)
         (org-mode)
         (set-buffer-modified-p nil)
         (goto-char (point-min))
         (search-forward "#+RESULTS:")
         (let ((start (line-beginning-position)))
           (goto-char (point-max))
           (set-mark start)
           (activate-mark)
           (should (use-region-p))
           (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
             (org-museum-derived-verify "derived-test" "Zero unmatched rows"))))
       (setq item (car org-museum-derived--items))
       (should (equal "recorded-result" (alist-get 'status item)))
       (should (org-museum-derived--verified-current-p item))
       (should (string-match-p "执行依据"
                               (org-museum-derived--recall-text
                                "exact rows" "a")))
       (with-temp-file result
         (insert "#+TITLE: Changed Result\n"))
       (should-not (org-museum-derived--verified-current-p item))
       (should (org-museum-derived--confirmed-p item))
       (should-not (string-match-p "执行依据"
                                   (org-museum-derived--recall-text
                                    "exact rows" "a")))))))

(ert-deftest org-museum-derived-model-unavailable-keeps-private-task ()
  (org-museum-derived-test--with-wiki
   (let* ((a (expand-file-name "a.org" org-museum-root-dir))
          (b (expand-file-name "b.org" org-museum-root-dir))
          (pages (make-hash-table :test 'equal)))
     (with-temp-file a (insert "#+TITLE: A\nMethod.\n"))
     (with-temp-file b (insert "#+TITLE: B\nEvidence.\n"))
     (puthash "a" (make-org-museum-page :id "a" :path a :title "A") pages)
     (puthash "b" (make-org-museum-page :id "b" :path b :title "B") pages)
     (setq org-museum--index (make-org-museum-index :pages pages))
     (with-temp-buffer
       (insert-file-contents a)
       (setq buffer-file-name a)
       (org-mode)
       (set-buffer-modified-p nil)
       (cl-letf (((symbol-function 'org-museum-derived--preflight)
                  (lambda (request)
                    (org-museum-derived--hold request "Model not loaded"))))
         (org-museum-derive-current "A question" "b")))
     (should (null org-museum-derived--active))
     (should (equal "pending-model"
                    (alist-get 'status (car org-museum-derived--items))))
     (should (file-exists-p (org-museum-derived--path)))
     (should (string-empty-p (org-museum-derived--recall-text "question" "a")))
     (setq org-museum-derived--root nil
           org-museum-derived--items nil)
     (org-museum-derived--ensure)
     (should (equal "pending-model"
                    (alist-get 'status (car org-museum-derived--items)))))))

(ert-deftest org-museum-derived-local-preflight-never-sends-unloaded-model ()
  (org-museum-derived-test--with-wiki
   (let* ((a (expand-file-name "a.org" org-museum-root-dir))
          (b (expand-file-name "b.org" org-museum-root-dir))
          (called 0))
     (with-temp-file a (insert "A source\n"))
     (with-temp-file b (insert "B source\n"))
     (let ((request `((id . "preflight-test") (task . "Combine A and B")
                      (sources . (((title . "A") (file . ,a) (line . 1)
                                   (excerpt . "A source")
                                   (hash . ,(org-museum-knowledge--file-hash a)))
                                  ((title . "B") (file . ,b) (line . 1)
                                   (excerpt . "B source")
                                   (hash . ,(org-museum-knowledge--file-hash b))))))))
       (setq org-museum-derived--active request)
       (cl-letf (((symbol-function 'url-retrieve)
                  (lambda (_url callback &rest _)
                    (let ((buffer (generate-new-buffer " *museum-model-check*")))
                      (with-current-buffer buffer
                        (insert "HTTP/1.1 200 OK\n\n"
                                "{\"models\":[{\"key\":\"google/gemma-4-e2b\","
                                "\"loaded_instances\":[]}]}")
                        (funcall callback nil)))))
                 ((symbol-function 'org-museum-derived--request)
                  (lambda (_request) (cl-incf called))))
         (org-museum-derived--preflight request))
       (should (= called 0))
       (should (null org-museum-derived--active))
       (should (equal "pending-model"
                      (alist-get 'status (car org-museum-derived--items))))
       (should (string-match-p "请先在 LM Studio 中加载 google/gemma-4-e2b"
                               (alist-get 'error
                                          (car org-museum-derived--items))))))))

(provide 'org-museum-derived-test)
;;; org-museum-derived-test.el ends here
