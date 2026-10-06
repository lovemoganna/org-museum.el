;;; org-museum-ai-web-test.el --- AI Center contract tests -*- lexical-binding: t -*-

(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8)

(require 'ert)
(setq load-prefer-newer t)
(require 'org-museum)

(defmacro org-museum-ai-web-test--with-wiki (&rest body)
  `(let* ((org-museum-root-dir (make-temp-file "org-museum-ai-web-" t))
          (org-museum--index nil)
          (org-museum-knowledge--root nil)
          (org-museum-knowledge--queue nil)
          (org-museum-knowledge--analyses nil)
          (org-museum-knowledge--experiences nil)
          (org-museum-knowledge--relations nil)
          (org-museum-knowledge--persist-timer nil)
          (org-museum-knowledge--auto-timer nil)
          (org-museum-ai-web--previews (make-hash-table :test #'equal))
          (file (expand-file-name "pages/first.org" org-museum-root-dir))
          (page nil))
     (unwind-protect
         (progn
           (make-directory (file-name-directory file) t)
           (with-temp-file file
             (insert "#+TITLE: First\n#+WIKI_ID: first\n#+CATEGORY: Test\nSaved source evidence.\n"))
           (setq page (make-org-museum-page :id "first" :path file
                                            :title "First" :status "published"))
           (setq org-museum--index
                 (make-org-museum-index
                  :categories (make-hash-table :test #'equal)
                  :tags (make-hash-table :test #'equal)
                  :pages (let ((table (make-hash-table :test #'equal)))
                           (puthash "first" page table) table)))
           (org-museum-knowledge--ensure)
           ,@body)
       (when (timerp org-museum-knowledge--persist-timer)
         (cancel-timer org-museum-knowledge--persist-timer))
       (when (timerp org-museum-knowledge--auto-timer)
         (cancel-timer org-museum-knowledge--auto-timer))
       (delete-directory org-museum-root-dir t))))

(ert-deftest org-museum-ai-web-query-decodes-chinese-page-id ()
  (let ((id "002-学习需要被设计"))
    (should (equal id (org-museum-ai-web--query
                       (concat "/api/v1/ai/page?pageId=" (url-hexify-string id))
                       "pageId")))))

(ert-deftest org-museum-ai-web-catalog-includes-page-category ()
  "The note picker receives the same category shown by the site."
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-category-label-alist '(("Test" . "测试分类"))))
     (setf (org-museum-page-category page) "Test")
     (let ((entry (aref (alist-get 'pages (org-museum-ai-web--catalog)) 0)))
       (should (equal "first" (alist-get 'id entry)))
       (should (equal "Test" (alist-get 'category entry)))
       (should (equal "测试分类" (alist-get 'categoryLabel entry)))))))

(ert-deftest org-museum-ai-web-worker-setting-validates-number ()
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-knowledge-max-workers 2))
     (should (= 3 (alist-get 'maxWorkers
                              (org-museum-ai-web--action
                               '((action . "workers") (maxWorkers . 3))))))
     (should-error (org-museum-ai-web--action
                    '((action . "workers") (maxWorkers . 0))))
     (should (= 3 org-museum-knowledge-max-workers)))))

(ert-deftest org-museum-ai-web-browser-catalog-preserves-display-label ()
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-category-label-alist '(("Test" . "测试分类"))))
     (setf (org-museum-page-category page) "Test")
     (let ((entry (aref (org-museum-ai-web--browser-pages
                         (expand-file-name "dist/ai-center.html" org-museum-root-dir)) 0)))
       (should (equal "Test" (alist-get 'category entry)))
       (should (equal "测试分类" (alist-get 'categoryLabel entry)))))))

(ert-deftest org-museum-ai-captures-group-by-org-category ()
  "Existing private captures gain a source CATEGORY without being republished."
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-category-label-alist '(("Test" . "测试分类")))
         (org-museum-ai-session--captures-root nil)
         (org-museum-ai-session--captures nil))
     (setf (org-museum-page-category page) "Test")
     (org-museum-ai-session--captures-ensure)
     (setq org-museum-ai-session--captures
           '(((id . "old-capture") (category . "结论")
              (title . "保留来源") (question . "如何复核？")
              (conclusion . "保留来源版本")
              (sources . [((pageId . "first") (title . "First"))]))))
     (let* ((result (org-museum-ai-session--capture-list nil nil "Test"))
            (entry (aref (alist-get 'captures result) 0))
            (source-category (aref (alist-get 'sourceCategories entry) 0)))
       (should (= 1 (alist-get 'total result)))
       (should (equal "Test" (alist-get 'value source-category)))
       (should (equal "测试分类" (alist-get 'label source-category)))
       (should (= 0 (alist-get 'total
                                (org-museum-ai-session--capture-list
                                 nil nil "Other"))))))))

(ert-deftest org-museum-ai-captures-reload-after-external-save ()
  "The private library reflects a saved file added after it was first read."
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-ai-session--captures-root nil)
         (org-museum-ai-session--captures-file-state nil)
         (org-museum-ai-session--captures nil))
     (org-museum-ai-session--captures-ensure)
     (should-not org-museum-ai-session--captures)
     (org-museum-knowledge--write-json
      (org-museum-ai-session--captures-path)
      '((schemaVersion . 1)
        (captures . [((id . "saved") (title . "Saved"))])))
     (org-museum-ai-session--captures-ensure)
     (should (= 1 (length org-museum-ai-session--captures))))))

(ert-deftest org-museum-ai-session-starts-mixed-cached-batch ()
  "Starting selected notes reuses one cached result and queues the other."
  (org-museum-ai-web-test--with-wiki
   (let* ((second-file (expand-file-name "pages/second.org" org-museum-root-dir))
          (second-page (make-org-museum-page :id "second" :path second-file
                                             :title "Second" :status "published"))
          (org-museum-ai-session--root nil)
          (org-museum-ai-session--items nil)
          (org-museum-ai-session--active nil)
          (org-museum-knowledge--actives nil)
          (org-museum-knowledge--batch nil))
     (with-temp-file second-file
       (insert "#+TITLE: Second\n#+WIKI_ID: second\nSecond source.\n"))
     (puthash "second" second-page (org-museum-index-pages org-museum--index))
     (setq org-museum-knowledge--analyses
           `(((file . ,file) (hash . ,(org-museum-knowledge--file-hash file))
              (summary . "Cached analysis"))))
     (cl-letf (((symbol-function 'org-museum-knowledge--backend)
                (lambda () 'backend))
               ((symbol-function 'org-museum-knowledge--preflight-local)
                (lambda (&rest _) nil)))
       (let ((session (org-museum-ai-session--start
                       '((pageIds . ("first" "second")) (batch . t)))))
         (should (equal "batching" (alist-get 'status session)))
         (should (= 1 (alist-get 'reused org-museum-knowledge--batch)))
         (should (= 2 (length (alist-get 'jobs org-museum-knowledge--batch)))))))))

(ert-deftest org-museum-ai-session-resumes-lost-batch ()
  "Polling a saved analysis resumes its batch after runtime reload."
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-ai-session--root nil)
         (org-museum-ai-session--items nil)
         (org-museum-knowledge--batch nil))
     (org-museum-ai-session--ensure)
     (setq org-museum-knowledge--analyses
           `(((file . ,file) (hash . ,(org-museum-knowledge--file-hash file))
              (summary . "Cached result"))))
     (let ((session `((id . "resume-test") (status . "batching")
                      (batchId . "lost-batch") (revision . 1)
                      (sources . (,(org-museum-ai-session--source "first")))
                      (turns . nil) (proposals . nil))))
       (setq org-museum-ai-session--items (list session))
       (let ((public (org-museum-ai-session--public session)))
         (should (equal "ready" (alist-get 'status public)))
         (should (equal "Cached result"
                        (alist-get 'summary
                                   (aref (alist-get 'analyses
                                                    (alist-get 'batch public)) 0)))))))))

(ert-deftest org-museum-ai-web-public-records-exclude-unapproved-and-stale ()
  (org-museum-ai-web-test--with-wiki
   (let* ((hash (org-museum-knowledge--file-hash file))
          (org-museum-knowledge--experiences
           `(((id . "approved") (file . ,file) (pageId . "first")
              (sourceHash . ,hash) (problem . "Problem")
              (result . "Verified fix") (published . t))
             ((id . "private") (file . ,file) (pageId . "first")
              (sourceHash . ,hash) (problem . "Secret")
              (result . "Never export") (published . nil))
             ((id . "stale") (file . ,file) (pageId . "first")
              (sourceHash . "old") (problem . "Old")
              (result . "Stale fix") (published . t)))))
     (let ((records (org-museum-ai-web--public-records
                     (expand-file-name "dist/ai-center.html" org-museum-root-dir))))
       (should (= 1 (length records)))
       (should (equal "Verified fix" (alist-get 'result (aref records 0))))))))

(ert-deftest org-museum-ai-web-page-reports-missing-analysis-honestly ()
  (org-museum-ai-web-test--with-wiki
   (org-museum-knowledge--mark-dirty file)
   (let ((job (org-museum-knowledge--job file)))
     (should (equal "dirty" (alist-get 'status
                                       (org-museum-ai-web--page-summary page))))
     (let ((org-museum-knowledge--requested-file file))
       (should (equal "queued" (alist-get 'status
                                          (org-museum-ai-web--page-summary page)))))
     (setf (alist-get 'status job) "done")
     (should (equal "stale" (alist-get 'status
                                      (org-museum-ai-web--page-summary page)))))))

(ert-deftest org-museum-ai-web-preview-requires-explicit-confirmation ()
  (org-museum-ai-web-test--with-wiki
   (let* ((data `((kind . "experience") (pageId . "first")
                  (expectedHash . ,(org-museum-knowledge--file-hash file))
                  (problem . "Duplicate rows") (result . "Use EXCEPT ALL")
                  (wrongAttempt . "Used EXCEPT")))
          (preview (org-museum-ai-web--preview data)))
     (should-not org-museum-knowledge--experiences)
     (cl-letf (((symbol-function 'org-museum--start-background-job)
                (lambda (&rest _) nil)))
       (org-museum-ai-web--confirm
        `((transactionId . ,(alist-get 'transactionId preview)))))
     (should (= 1 (length org-museum-knowledge--experiences)))
     (should (eq t (alist-get 'published (car org-museum-knowledge--experiences))))
     (should (string-match-p
              "Duplicate rows"
              (org-museum-ai-web--dispatch-http
               "GET" "/api/v1/ai/public" nil)))
     (should-error
      (org-museum-ai-web--confirm
       `((transactionId . ,(alist-get 'transactionId preview))))))))

(ert-deftest org-museum-ai-web-evidence-must-match-saved-source ()
  (org-museum-ai-web-test--with-wiki
   (should-error
    (org-museum-ai-web--preview
     `((kind . "relation") (pageId . "first") (targetId . "first")
       (expectedHash . ,(org-museum-knowledge--file-hash file))
       (relationType . "related") (evidence . "Invented source evidence"))))))

(ert-deftest org-museum-ai-web-export-contains-approved-only ()
  (org-museum-ai-web-test--with-wiki
   (let* ((hash (org-museum-knowledge--file-hash file))
          (org-museum-knowledge--experiences
           `(((id . "approved") (file . ,file) (pageId . "first")
              (sourceHash . ,hash) (problem . "Repeat problem")
              (result . "Confirmed result") (published . t))
             ((id . "draft") (file . ,file) (pageId . "first")
              (sourceHash . ,hash) (problem . "Private problem")
              (result . "Private analysis") (published . nil)))))
     (org-museum--ensure-css-deployed)
     (org-museum-ai-web--export-center)
     (let* ((root (org-museum--shared-root))
            (html (with-temp-buffer
                    (insert-file-contents (expand-file-name "ai-center.html" root))
                    (buffer-string)))
            (data (with-temp-buffer
                    (insert-file-contents (expand-file-name "ai-public.json" root))
                    (buffer-string))))
       (should (string-match-p "AI 中心" html))
       (should (string-match-p "1 · 分析一篇笔记" html))
       (should (string-match-p "2 · 找相关经验" html))
       (should (string-match-p "3 · 任务结束后沉淀" html))
       (should (string-match-p "data-ai-workers" html))
       (should (string-match-p "data-ai-source-category" html))
       (should (string-match-p "从已收录结论整理" html))
       (should (string-match-p "data-ai-offline hidden" html))
       (should (string-match-p "<details class=\"museum-ai-advanced\"" html))
       (should (string-match-p "Confirmed result" html))
       (should (string-match-p "Confirmed result" data))
       (should-not (string-match-p "Private analysis" html))
       (should-not (string-match-p "Private analysis" data))))))

(ert-deftest org-museum-ai-web-api-requires-local-session ()
  (org-museum-ai-web-test--with-wiki
   (let* ((org-museum--curation-token "local-session-test")
          (org-museum--curation-server-port 49152)
          (unauthorized (org-museum--curation-dispatch-http
                         "GET" "/api/v1/ai/status" nil ""))
          (authorized (org-museum--curation-dispatch-http
                       "GET" "/api/v1/ai/status"
                       '(("authorization" . "Bearer local-session-test")
                         ("x-org-museum-curation" . "1")
                         ("origin" . "http://127.0.0.1:49152")) "")))
     (should (string-prefix-p "HTTP/1.1 409" unauthorized))
     (should-not (string-match-p "First" unauthorized))
     (should (string-prefix-p "HTTP/1.1 200" authorized))
     (should (string-match-p "Cache-Control: no-store\r\n" authorized))
     (should (string-match-p "google/gemma-4-e2b" authorized)))))

(ert-deftest org-museum-ai-web-local-pages-reuse-static-resources ()
  (org-museum-ai-web-test--with-wiki
   (org-museum--ensure-css-deployed)
   (should-not (org-museum--ai-resources-need-deployment-p))
   (org-museum-ai-web--export-center)
   (should-not (org-museum--ai-center-needs-export-p))
   (with-temp-file (expand-file-name "ai-center.html" (org-museum--shared-root))
     (insert "<html><body>outdated AI center</body></html>"))
   (should (org-museum--ai-center-needs-export-p))
   (let* ((html (org-museum--curation-dispatch-http
                 "GET" "/ai-center.html" nil ""))
          (css (org-museum--curation-dispatch-http
                "GET" "/resources/org-museum.css?v=abcdef123456" nil ""))
          (font (org-museum--curation-dispatch-http
                 "GET" "/resources/fonts/VictorMono-Roman-v1.564.woff2" nil ""))
          (font-body (substring font (+ 4 (string-match "\r\n\r\n" font))))
          (font-file (expand-file-name
                      "resources/fonts/VictorMono-Roman-v1.564.woff2"
                      (org-museum--shared-root)))
          (font-original (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally font-file)
                           (buffer-string))))
     (should (string-prefix-p "HTTP/1.1 200" html))
     (should (string-match-p "data-ai-cancel-session" html))
     (should-not (string-match-p "outdated AI center" html))
     (should (string-match-p "Cache-Control: no-store\r\n" html))
     (should (string-match-p
              "Cache-Control: private, max-age=31536000, immutable\r\n" css))
     (should (string-match-p "Cache-Control: private, max-age=86400\r\n" font))
     (should (equal font-original font-body)))))

(ert-deftest org-museum-ai-web-reopening-center-keeps-navigation-session ()
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-curation-mode 'loopback)
         (org-museum-curation-port 0)
         (org-museum--curation-server nil)
         (org-museum--curation-server-port nil)
         (org-museum--curation-token nil))
     (unwind-protect
         (progn
           (org-museum--ensure-css-deployed)
           (org-museum-ai-web--export-center)
           (with-temp-file (expand-file-name "index.html" (org-museum--shared-root))
             (insert "<html><body>Home</body></html>"))
           (cl-letf (((symbol-function 'browse-url) (lambda (&rest _) nil)))
             (org-museum-curation-server-start "ai-center.html")
             (let ((server org-museum--curation-server)
                   (port org-museum--curation-server-port)
                   (token org-museum--curation-token))
               (org-museum-curation-server-start "index.html")
               (should (eq server org-museum--curation-server))
               (should (equal port org-museum--curation-server-port))
               (should (equal token org-museum--curation-token)))))
       (org-museum-curation-server-stop)))))

(ert-deftest org-museum-ai-session-captures-searches-and-reuses-answer ()
  (org-museum-ai-web-test--with-wiki
   (let* ((org-museum-ai-session--root (file-truename org-museum-root-dir))
          (org-museum-ai-session--items nil)
          (org-museum-ai-session--captures-root nil)
          (org-museum-ai-session--captures nil)
          (org-museum-ai-session--active nil)
          (session `((id . "discussion") (createdAt . "2026-09-29T10:00:00+0800")
                     (status . "ready") (revision . 1)
                     (sources . ,(list (org-museum-ai-session--source "first")))
                     (turns . (((id . "analysis") (kind . "analysis")
                                (createdAt . "2026-09-29T10:00:00+0800")
                                (prompt . "分析原文") (answer . "原文给出初步判断")
                                (status . "done"))
                               ((id . "answer-2") (kind . "dialogue")
                                (createdAt . "2026-09-29T10:02:00+0800")
                                (prompt . "如何保留来源？")
                                (answer . "结论：保留笔记链接和来源版本。")
                                (status . "done"))))
                     (directions . nil) (proposals . nil)))
          captured prompt)
     (setq org-museum-ai-session--items (list session))
     (org-museum-ai-session--save)
     (should-error
      (org-museum-ai-session--capture-add
       '((sessionId . "discussion") (turnId . "missing"))))
     (setq captured (alist-get 'capture
                              (org-museum-ai-session--capture-add
                               '((sessionId . "discussion") (turnId . "answer-2")))))
     (should (equal "如何保留来源？" (alist-get 'question captured)))
     (should (equal "原文给出初步判断"
                    (alist-get 'answer (aref (alist-get 'context captured) 0))))
     (should (equal "first" (alist-get 'pageId
                                      (aref (alist-get 'sources captured) 0))))
     (should (equal "pages/first.html"
                    (alist-get 'href
                               (aref (alist-get 'sources captured) 0))))
     (should (equal "2026-09-29T10:02:00+0800"
                    (alist-get 'createdAt (cadr (alist-get 'turns session)))))
     (should (alist-get 'alreadySaved
                             (org-museum-ai-session--capture-add
                              '((sessionId . "discussion") (turnId . "answer-2")))))
     (org-museum-ai-session--capture-update
      `((captureId . ,(alist-get 'id captured)) (title . "可追溯结论")
        (category . "方法") (conclusion . "引用时保留来源版本")))
     (setq org-museum-ai-session--captures-root nil
           org-museum-ai-session--captures nil)
     (should (= 1 (alist-get 'total
                            (org-museum-ai-session--capture-list "来源版本" "方法"))))
     (should (= 0 (alist-get 'total
                            (org-museum-ai-session--capture-list "来源版本" "经验"))))
     (should (equal "结论：保留笔记链接和来源版本。"
                    (alist-get 'answer
                               (org-museum-ai-session--capture-get
                                (alist-get 'id captured)))))
     (org-museum--ensure-css-deployed)
     (org-museum-ai-web--export-center)
     (should-not
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name "ai-center.html" (org-museum--shared-root)))
        (goto-char (point-min))
        (search-forward "可追溯结论" nil t)))
     (let* ((org-museum--curation-token "capture-private-test")
            (org-museum--curation-server-port 49153)
            (path "/api/v1/ai/captures?q=%E6%9D%A5%E6%BA%90%E7%89%88%E6%9C%AC")
            (blocked (org-museum--curation-dispatch-http "GET" path nil ""))
            (allowed (org-museum--curation-dispatch-http
                      "GET" path
                      '(("authorization" . "Bearer capture-private-test")
                        ("x-org-museum-curation" . "1")
                        ("origin" . "http://127.0.0.1:49153")) ""))
            (detail (org-museum--curation-dispatch-http
                     "GET" (concat "/api/v1/ai/capture?captureId="
                                   (alist-get 'id captured))
                     '(("authorization" . "Bearer capture-private-test")
                       ("x-org-museum-curation" . "1")
                       ("origin" . "http://127.0.0.1:49153")) "")))
       (should (string-prefix-p "HTTP/1.1 409" blocked))
       (should-not (string-match-p "可追溯结论" blocked))
       (should (string-match-p "可追溯结论"
                               (decode-coding-string allowed 'utf-8)))
       (should-not (string-match-p "\"context\"" allowed))
       (should (string-match-p "\"context\"" detail)))
     (cl-letf (((symbol-function 'org-museum-ai-session--request)
                (lambda (full-prompt _system _stream callback &optional _limit)
                  (setq prompt full-prompt)
                  (funcall callback "引用后的回答" nil)
                  (funcall callback t nil)))
               ((symbol-function 'org-museum-ai-session--recommend)
                (lambda (_session) nil)))
       (org-museum-ai-session--message
        `((sessionId . "discussion") (message . "继续验证")
          (captureId . ,(alist-get 'id captured)))))
     (should (string-match-p "引用时保留来源版本" prompt))
     (should (string-match-p
              (alist-get 'hash (aref (alist-get 'sources captured) 0)) prompt))
     (should (equal (alist-get 'id captured)
                    (alist-get 'referenceId
                               (car (last (alist-get 'turns session)))))))))

(ert-deftest org-museum-ai-session-takeaway-requires-answer-evidence ()
  (let ((turn '((answer . "分析指出：保留笔记链接和来源版本，才能再次核对结论。"))))
    (should
     (equal "保留笔记链接和来源版本"
            (alist-get 'conclusion
                       (org-museum-ai-session--parse-takeaway
                        '((title . "可追溯结论")
                          (conclusion . "保留笔记链接和来源版本")
                          (category . "方法")
                          (evidence . "保留笔记链接和来源版本"))
                        turn))))
    (should-not
     (org-museum-ai-session--parse-takeaway
      '((title . "未经证实结论") (conclusion . "没有依据的结论")
        (category . "方法") (evidence . "原回答不存在的依据")) turn))))

(ert-deftest org-museum-ai-session-streams-remembers-and-recommends ()
  (org-museum-ai-web-test--with-wiki
   (let* ((second-file (expand-file-name "pages/second.org" org-museum-root-dir))
          (second-page (make-org-museum-page :id "second" :path second-file
                                             :title "Second" :status "published"))
          (calls 0) prompts)
     (with-temp-file second-file
       (insert "#+TITLE: Second\n#+WIKI_ID: second\n#+CATEGORY: Test\nSecond source evidence.\n"))
     (puthash "second" second-page (org-museum-index-pages org-museum--index))
     (let ((org-museum-ai-session--root nil)
           (org-museum-ai-session--items nil)
           (org-museum-ai-session--active nil))
       (cl-letf (((symbol-function 'org-museum-ai-session--request)
                  (lambda (prompt _system _stream callback &optional _max-tokens)
                    (push prompt prompts)
                    (cl-incf calls)
                    (pcase calls
                      (1 (funcall callback "共同结论：" nil)
                         (should (equal "streaming"
                                        (alist-get 'status
                                                   (car org-museum-ai-session--items))))
                         (funcall callback "两篇资料相互补充。" nil)
                         (funcall callback t nil))
                      (2 (funcall callback
                                  (concat "{\"directions\":[{\"title\":\"核对两份证据\","
                                          "\"reason\":\"两篇资料分别记录了不同来源依据\","
                                          "\"question\":\"请比较两份来源依据\","
                                          "\"sourcePageIds\":[\"first\",\"second\"]}],"
                                          "\"proposals\":[]}") nil)
                         (funcall callback t nil))
                      (3 (funcall callback
                                  (concat "{\"directions\":["
                                          "{\"title\":\"核对两份证据\",\"reason\":\"比较两篇资料的依据来源\",\"question\":\"请比较两份来源依据\",\"sourcePageIds\":[\"first\",\"second\"]},"
                                          "{\"title\":\"检查冲突之处\",\"reason\":\"两篇资料可能存在不同判断\",\"question\":\"请指出需要核实的冲突\",\"sourcePageIds\":[\"first\",\"second\"]},"
                                          "{\"title\":\"提炼共同方法\",\"reason\":\"两篇资料可以形成共同做法\",\"question\":\"请提炼可复用的方法\",\"sourcePageIds\":[\"first\",\"second\"]}]}" ) nil)
                         (funcall callback t nil))
                      (4 (funcall callback
                                  "{\"proposals\":[{\"type\":\"conclusion\",\"title\":\"保留来源依据\",\"body\":\"分析结论需要保留原文依据。\",\"targetPageId\":\"first\",\"sourcePageIds\":[\"first\"],\"evidence\":\"Saved source evidence.\",\"verification\":\"verified\"}]}"
                                  nil)
                         (funcall callback t nil))
                      (5 (funcall callback "进一步比较后仍需验证。" nil)
                         (funcall callback t nil))
                      (6 (funcall callback
                                  (concat "{\"directions\":["
                                          "{\"title\":\"方向甲\",\"reason\":\"有资料依据可以继续核对\",\"question\":\"请继续核对方向甲\",\"sourcePageIds\":[\"first\"]},"
                                          "{\"title\":\"方向乙\",\"reason\":\"有资料依据可以继续比较\",\"question\":\"请继续比较方向乙\",\"sourcePageIds\":[\"second\"]},"
                                          "{\"title\":\"方向丙\",\"reason\":\"有资料依据可以继续验证\",\"question\":\"请继续验证方向丙\",\"sourcePageIds\":[\"first\",\"second\"]}]}" ) nil)
                         (funcall callback t nil))
                      (7 (funcall callback "{\"proposals\":[]}" nil)
                         (funcall callback t nil))))))
         (let* ((session (org-museum-ai-session--start
                          '((pageIds . ("first" "second")))))
                (id (alist-get 'id session))
                (direction (aref (alist-get 'directions session) 0)))
           (should (= 2 (length (alist-get 'sources session))))
           (should (equal "ready" (alist-get 'status session)))
           (should (equal "核对两份证据" (alist-get 'title direction)))
           (org-museum-ai-session--message
            `((sessionId . ,id) (directionId . ,(alist-get 'id direction))))
           (should (string-match-p "共同结论" (car prompts)))
           (should (string-match-p "请比较两份来源依据" (car prompts)))
           (should (= 2 (length (alist-get 'turns
                                           (org-museum-ai-session--get id)))))
           (should (= 2 (length (alist-get 'turns
                                           (car (alist-get 'sessions
                                                           (org-museum-knowledge--read-json
                                                            (org-museum-ai-session--path))))))))
           (let ((org-museum-ai-session--root nil)
                 (org-museum-ai-session--items nil))
             (should (= 2 (length (alist-get 'turns
                                             (org-museum-ai-session--get id))))))))))))

(ert-deftest org-museum-ai-session-preview-confirm-and-conflict ()
  (org-museum-ai-web-test--with-wiki
   (let* ((org-museum-ai-session--root nil)
          (org-museum-ai-session--items nil)
          (org-museum-ai-session--active nil)
          (session `((id . "session") (status . "ready") (revision . 1)
                     (sources . (((pageId . "first") (title . "First")
                                  (hash . ,(org-museum-knowledge--file-hash file)))))
                     (turns . nil) (directions . nil)
                     (proposals . (((id . "proposal") (type . "todo")
                                    (title . "验证修复") (body . "核对实际执行后的修复结果")
                                    (targetPageId . "first")
                                    (sourcePageIds . ("first"))
                                    (evidence . "Saved source evidence.")
                                    (verification . "inference")
                                    (status . "suggested"))))))
          (exports 0) (backups 0))
     (setq org-museum-ai-session--root (file-truename org-museum-root-dir)
           org-museum-ai-session--items (list session))
     (cl-letf (((symbol-function 'org-museum--curation-persist-backups)
                (lambda (&rest _) (cl-incf backups)))
               ((symbol-function 'org-museum-export-all)
                (lambda (&rest _) (cl-incf exports)))
               ((symbol-function 'org-roam-db-sync) (lambda (&rest _) nil)))
       (let* ((preview (org-museum-ai-session--preview
                        '((sessionId . "session") (proposalId . "proposal")
                          (title . "验证修复") (body . "核对实际执行后的修复结果"))))
              (transaction (alist-get 'transactionId preview)))
         (should-not (string-match-p "AI 协作沉淀"
                                     (with-temp-buffer (insert-file-contents file)
                                                       (buffer-string))))
         (with-temp-file file
           (insert "#+TITLE: First\n#+WIKI_ID: first\n#+CATEGORY: Test\nChanged source.\n"))
         (should-error (org-museum-ai-session--confirm
                        `((transactionId . ,transaction))))
         (should (= 0 exports))
         (with-temp-file file
           (insert "#+TITLE: First\n#+WIKI_ID: first\n#+CATEGORY: Test\nSaved source evidence.\n"))
         (org-museum-ai-session--confirm `((transactionId . ,transaction)))
         (should (= 1 backups))
         (should (= 1 exports))
         (should-not (org-museum-ai-session--stale session))
         (let ((text (with-temp-buffer (insert-file-contents file)
                                       (buffer-string))))
           (should (string-match-p "\\* AI 协作沉淀" text))
           (should (string-match-p "\\*\\* TODO 验证修复" text))
           (should (string-match-p "待验证推断" text)))
         (should-error (org-museum-ai-session--confirm
                        `((transactionId . ,transaction)))))))))

(ert-deftest org-museum-ai-session-appends-within-existing-section ()
  (org-museum-ai-web-test--with-wiki
   (let* ((second-file (expand-file-name "pages/second.org" org-museum-root-dir))
          (second-page (make-org-museum-page :id "second" :path second-file
                                             :title "Second" :status "published"))
          (session '((id . "session")))
          (proposal '((id . "proposal") (type . "method")
                      (sourcePageIds . ("first" "second"))
                      (evidence . "Saved source evidence.")
                      (verification . "verified")))
          (record '((targetPageId . "first") (title . "保留章节顺序")
                    (body . "方法内容")))
          result)
     (with-temp-file second-file (insert "#+TITLE: Second\n"))
     (puthash "second" second-page (org-museum-index-pages org-museum--index))
     (setq result (org-museum-ai-session--append-content
                   "* 原文\nSaved source evidence.\n* AI 协作沉淀\n** 已有条目\n旧内容\n* 后续章节\n其他内容\n"
                   session proposal record))
     (should (string-match-p
              "\\*\\* 已有条目\\(?:.\\|\n\\)*\\*\\* 方法 保留章节顺序\\(?:.\\|\n\\)*\\* 后续章节"
              result))
     (should (string-match-p "\\[\\[file:second.org\\]\\[Second\\]\\]" result))
     (let ((first (string-match "^\\* AI 协作沉淀$" result)))
       (should first)
       (should-not (string-match "^\\* AI 协作沉淀$" result (1+ first)))))))

(ert-deftest org-museum-ai-session-cancel-keeps-late-callback-interrupted ()
  (org-museum-ai-web-test--with-wiki
   (let ((org-museum-ai-session--root nil)
         (org-museum-ai-session--items nil)
         (org-museum-ai-session--active nil)
         callbacks)
     (cl-letf (((symbol-function 'org-museum-ai-session--request)
                (lambda (_prompt _system _stream callback &optional _max-tokens)
                  (push callback callbacks))))
       (let* ((created (org-museum-ai-session--start '((pageIds . ("first")))))
              (id (alist-get 'id created)))
         (funcall (car callbacks) "分析结果" nil)
         (funcall (car callbacks) t nil)
         (should (equal "recommending"
                        (alist-get 'status (org-museum-ai-session--get id))))
         (should (eq org-museum-ai-session--active
                     (org-museum-ai-session--get id)))
         (org-museum-ai-session--cancel `((sessionId . ,id)))
         (funcall (car callbacks) t nil)
         (should (equal "interrupted"
                        (alist-get 'status (org-museum-ai-session--get id)))))))))

(ert-deftest org-museum-ai-web-article-panel-html-renders-right-sidebar-and-copilot-chat ()
  "Article AI panel exports an independent right sidebar Copilot with chat area."
  (let ((html (org-museum-ai-web--article-panel-html nil)))
    (should (string-match-p "class=\"[^\"]*museum-ai-sidebar[^\"]*\"" html))
    (should (string-match-p "class=\"[^\"]*museum-ai-copilot-header[^\"]*\"" html))
    (should (string-match-p "data-ai-engine-badge" html))
    (should (string-match-p "data-copilot-new" html))
    (should (string-match-p "data-copilot-config-toggle" html))
    (should (string-match-p "data-copilot-model-select" html))
    (should (string-match-p "data-copilot-model-refresh" html))
    (should (string-match-p "data-copilot-model-config" html))
    (should (string-match-p "data-ai-context-title" html))
    (should (string-match-p "data-ai-analyze" html))
    (should (string-match-p "data-ai-analysis-drawer" html))
    (should (string-match-p "data-ai-chat-turns" html))
    (should (string-match-p "data-ai-explore-chips" html))
    (should (string-match-p "data-ai-chat-form" html))
    (should (string-match-p "data-ai-chat-input" html))
    (should (string-match-p "data-ai-chat-stop" html))
    (should (string-match-p "data-ai-chat-send" html))))

(provide 'org-museum-ai-web-test)
;;; org-museum-ai-web-test.el ends here
