;;; org-museum-gap-test.el --- Task gaps and deep scan tests -*- lexical-binding: t -*-

(require 'ert)
(setq load-prefer-newer t)
(require 'org-museum)

(defmacro org-museum-gap-test--with-wiki (&rest body)
  `(let* ((org-museum-root-dir (make-temp-file "org-museum-gap-" t))
          (org-museum-knowledge--root nil)
          (org-museum-knowledge--queue nil)
          (org-museum-knowledge--analyses nil)
          (org-museum-knowledge--experiences nil)
          (org-museum-knowledge--relations nil)
          (org-museum-derived--root nil)
          (org-museum-derived--items nil)
          (org-museum-gap--root nil)
          (org-museum-gap--reports nil)
          (org-museum-gap--active nil)
          (org-museum-deep-scan--job nil)
          (org-museum-deep-scan--timer nil)
          (org-museum-deep-scan--last-report nil)
          (org-museum--index nil))
     (unwind-protect (progn ,@body)
       (when (timerp org-museum-deep-scan--timer)
         (cancel-timer org-museum-deep-scan--timer))
       (delete-directory org-museum-root-dir t))))

(ert-deftest org-museum-gap-stays-task-scoped-and-distinguishes-evidence ()
  (org-museum-gap-test--with-wiki
   (let* ((a (expand-file-name "a.org" org-museum-root-dir))
          (b (expand-file-name "b.org" org-museum-root-dir))
          (c (expand-file-name "c.org" org-museum-root-dir))
          (page-a (make-org-museum-page
                   :id "a" :path a :title "DuckDB row comparison"
                   :links-to '("b")))
          (page-b (make-org-museum-page
                   :id "b" :path b :title "EXCEPT ALL evidence"
                   :linked-from '("a")))
          (page-c (make-org-museum-page
                   :id "c" :path c :title "Unrelated gardening"))
          (table (make-hash-table :test 'equal))
          (model-calls 0))
     (with-temp-file a
       (insert "#+TITLE: DuckDB row comparison\nUse VALUES for expected rows.\n"))
     (with-temp-file b
       (insert "#+TITLE: EXCEPT ALL evidence\n#+RESULTS:\n: zero rows\n"))
     (with-temp-file c
       (insert "#+TITLE: Unrelated gardening\nPlant seeds.\n"))
     (puthash "a" page-a table)
     (puthash "b" page-b table)
     (puthash "c" page-c table)
     (setq org-museum--index (make-org-museum-index :pages table))
     (let* ((task "Debug DuckDB row comparison")
            (scope (org-museum-gap--scope task page-a))
            (ids (mapcar #'org-museum-page-id (plist-get scope :pages)))
            (observations (org-museum-gap--observations scope))
            (findings (org-museum-gap--local-findings scope observations)))
       (should (member "a" ids))
       (should (member "b" ids))
       (should-not (member "c" ids))
       (should (equal "已连接"
                      (alist-get 'maturity (car observations))))
       (should (cl-some (lambda (item)
                          (equal "有记录依据" (alist-get 'maturity item)))
                        observations))
       (should-not (member "verification"
                           (mapcar (lambda (item) (alist-get 'kind item))
                                   findings)))
       (should (member "failure"
                       (mapcar (lambda (item) (alist-get 'kind item))
                               findings))))
     (with-temp-buffer
       (insert-file-contents a)
       (setq buffer-file-name a)
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (&rest _) (cl-incf model-calls))))
         (org-museum-knowledge-gap "Debug DuckDB row comparison")))
     (should (= model-calls 0))
     (with-current-buffer "*Org Museum 知识缺口*"
       (should (string-match-p "当前任务" (buffer-string)))
       (should (string-match-p "知识成熟度" (buffer-string)))
       (should-not (string-match-p "Unrelated gardening" (buffer-string))))
     (should (equal 'org-museum-knowledge-gap
                    (lookup-key org-museum-mode-map (kbd "C-c w ?")))))))

(ert-deftest org-museum-gap-model-report-is-private-sourced-and-stales ()
  (org-museum-gap-test--with-wiki
   (let* ((file (expand-file-name "source.org" org-museum-root-dir))
          (page (make-org-museum-page
                 :id "source" :path file :title "Debugging source"))
          (table (make-hash-table :test 'equal)))
     (with-temp-file file
       (insert "#+TITLE: Debugging source\nObserve a failing case.\n"))
     (puthash "source" page table)
     (setq org-museum--index (make-org-museum-index :pages table))
     (should-error
      (org-museum-gap--parse-response
       "{\"gaps\":[{\"need\":\"N\",\"why\":\"W\",\"validation\":\"V\",\"source_ids\":[\"invented\"]}]}"
       '("source")))
     (should-not (org-museum-gap--parse-response "{\"gaps\":[]}" '("source")))
     (org-museum-knowledge-gap "Debugging evidence")
     (with-current-buffer "*Org Museum 知识缺口*"
       (let* ((observations (plist-get org-museum-gap--view :observations))
              (request `((id . ,(org-museum-gap--report-id
                                org-museum-gap--task observations))
                         (task . ,org-museum-gap--task)
                         (sources . (((pageId . "source") (file . ,file)
                                      (hash . ,(org-museum-knowledge--file-hash
                                                file))))))))
         (setq org-museum-gap--active request)
         (org-museum-gap--finish
          request
          "{\"gaps\":[{\"need\":\"Record a failure case\",\"why\":\"Only a description is present\",\"validation\":\"Run and save a result\",\"source_ids\":[\"source\"]}]}"
          nil)
         (should (equal "ai-inference"
                        (alist-get 'status (car org-museum-gap--reports))))
         (should (file-exists-p (org-museum-gap--path)))
         (should (string-match-p "Record a failure case" (buffer-string)))
         (setq org-museum-gap--root nil
               org-museum-gap--reports nil)
         (org-museum-gap--ensure)
         (should (= 1 (length org-museum-gap--reports)))
         (with-temp-file file
           (insert "#+TITLE: Changed source\n"))
         (should-not (org-museum-gap--report-current-p
                      (car org-museum-gap--reports)))
         (org-museum-gap--render)
         (should (string-match-p "来源已变化" (buffer-string)))
         (should-not (string-match-p "Record a failure case"
                                     (buffer-string))))))))

(ert-deftest org-museum-gap-local-preflight-uses-loaded-gemma-only ()
  (org-museum-gap-test--with-wiki
   (let ((called 0)
         (request '((id . "gemma") (task . "A task") (sources . nil))))
     (setq org-museum-gap--active request)
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (_url callback &rest _)
                  (let ((buffer (generate-new-buffer " *gap-model-check*")))
                    (with-current-buffer buffer
                      (insert "HTTP/1.1 200 OK\n\n"
                              "{\"models\":[{\"key\":\"google/gemma-4-e2b\","
                              "\"loaded_instances\":[{\"id\":\"google/gemma-4-e2b\"}]}]}")
                      (funcall callback nil)))))
               ((symbol-function 'org-museum-gap--send-request)
                (lambda (_request _prompt) (cl-incf called))))
       (org-museum-gap--preflight request "prompt"))
     (should (= 1 called))
     (should (eq request org-museum-gap--active)))))

(ert-deftest org-museum-gap-gptel-reasoning-precedes-final-answer ()
  "A reasoning callback must not consume the active request."
  (org-museum-gap-test--with-wiki
   (let* ((request '((id . "reasoning") (task . "Verify rows")
                     (sources . nil)))
          callback
          completed)
     (setq org-museum-gap--active request)
     (cl-letf (((symbol-function 'org-museum-knowledge--backend)
                (lambda () 'local-backend))
               ((symbol-function 'gptel-request)
                (lambda (_prompt &rest args)
                  (setq callback (plist-get args :callback))))
               ((symbol-function 'org-museum-gap--finish)
                (lambda (actual response _status)
                  (setq completed (list actual response)))))
       (org-museum-gap--send-request request "Review this task")
       (should-not completed)
       (should (equal "google/gemma-4-e2b"
                      (alist-get 'model org-museum-gap--active)))
       (funcall callback '(reasoning . "thinking")
                '(:status "HTTP/1.1 200 OK"))
       (should-not completed)
       (funcall callback "{\"gaps\":[]}"
                '(:status "HTTP/1.1 200 OK"))
       (should (eq (car completed) org-museum-gap--active))
       (should (equal (cadr completed) "{\"gaps\":[]}")))
     (when (buffer-live-p org-museum-gap--request-buffer)
       (kill-buffer org-museum-gap--request-buffer)))))

(ert-deftest org-museum-deep-scan-is-explicit-batched-and-cancellable ()
  (org-museum-gap-test--with-wiki
   (let* ((a (expand-file-name "a.org" org-museum-root-dir))
          (b (expand-file-name "b.org" org-museum-root-dir))
          (c (expand-file-name "c.org" org-museum-root-dir))
          (page-a (make-org-museum-page
                   :id "a" :path a :title "A" :links-to '("b")
                   :linked-from '("b")))
          (page-b (make-org-museum-page
                   :id "b" :path b :title "B" :links-to '("a")
                   :linked-from '("a")))
          (page-c (make-org-museum-page
                   :id "c" :path c :title "C"))
          (table (make-hash-table :test 'equal)))
     (with-temp-file a (insert "Same content\n"))
     (with-temp-file b (insert "Same content\n"))
     (with-temp-file c (insert "Isolated content\n"))
     (puthash "a" page-a table)
     (puthash "b" page-b table)
     (puthash "c" page-c table)
     (setq org-museum--index (make-org-museum-index :pages table))
     (org-museum-knowledge--ensure)
     (setq org-museum-knowledge--queue
           `(((file . ,a) (status . "dirty") (attempts . 0))))
     (setq org-museum-knowledge--relations
           (list `((sourcePageId . "a") (targetPageId . "b")
                   (sourceFile . ,a) (targetFile . ,b)
                   (sourceHash . ,(org-museum-knowledge--file-hash a))
                   (targetHash . ,(org-museum-knowledge--file-hash b))
                   (type . "supports") (confidence . 0.4))
                 `((sourcePageId . "a") (targetPageId . "b")
                   (sourceFile . ,a) (targetFile . ,b)
                   (sourceHash . ,(org-museum-knowledge--file-hash a))
                   (targetHash . ,(org-museum-knowledge--file-hash b))
                   (type . "contradicts") (confidence . 0.9))))
     (let ((org-museum-deep-scan-batch-size 1))
       (cl-letf (((symbol-function 'org-museum-index-build)
                  (lambda (&optional _) org-museum--index))
                 ((symbol-function 'run-at-time)
                  (lambda (&rest _) 'deferred)))
         (org-museum-deep-scan)
         (should (= 0 (plist-get org-museum-deep-scan--job :position)))
         (org-museum-deep-scan--step)
         (should (= 1 (plist-get org-museum-deep-scan--job :position)))
         (org-museum-deep-scan-cancel)
         (should-not org-museum-deep-scan--job)
         (org-museum-deep-scan)
         (while org-museum-deep-scan--job
           (org-museum-deep-scan--step))))
     (let* ((report org-museum-deep-scan--last-report)
            (counts (plist-get report :counts)))
       (should (= 3 (plist-get report :scanned)))
       (should (= 1 (alist-get 'duplicates counts)))
       (should (= 1 (alist-get 'conflicts counts)))
       (should (= 1 (alist-get 'isolated counts)))
       (should (= 1 (alist-get 'lowConfidence counts)))
       (should (= 1 (alist-get 'dirty counts)))
       (should (<= (length (plist-get report :findings)) 12))
       (should (string-match-p "重复 1" (with-current-buffer
                                         "*Org Museum 深度巡检*"
                                       (buffer-string))))
       (should (equal 'org-museum-deep-scan
                      (lookup-key org-museum-mode-map (kbd "C-c w S"))))))))

(provide 'org-museum-gap-test)
;;; org-museum-gap-test.el ends here
