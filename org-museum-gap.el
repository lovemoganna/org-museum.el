;;; org-museum-gap.el --- Task gaps and explicit governance scan -*- lexical-binding: t -*-

;; Loaded after the Org Museum knowledge, context and derived modules.
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)

(defgroup org-museum-gap nil
  "Private knowledge gap views for Org Museum."
  :group 'org-museum-knowledge)

(defcustom org-museum-gap-max-pages 6
  "Maximum number of indexed notes inspected for one task view."
  :type 'integer :group 'org-museum-gap)

(defcustom org-museum-gap-model-source-limit 900
  "Maximum source characters per note sent to the chosen gap model."
  :type 'integer :group 'org-museum-gap)

(defcustom org-museum-deep-scan-batch-size 20
  "Number of indexed notes read per idle Deep Scan step."
  :type 'integer :group 'org-museum-gap)

(defcustom org-museum-deep-scan-low-confidence 0.6
  "Private relation confidence below this value is flagged for review."
  :type 'number :group 'org-museum-gap)

(defvar org-museum-gap--root nil)
(defvar org-museum-gap--reports nil)
(defvar org-museum-gap--active nil)
(defvar org-museum-gap--request-buffer nil)
(defvar org-museum-deep-scan--job nil)
(defvar org-museum-deep-scan--timer nil)
(defvar org-museum-deep-scan--last-report nil)
(defvar-local org-museum-gap--task nil)
(defvar-local org-museum-gap--anchor-id nil)
(defvar-local org-museum-gap--view nil)

(defun org-museum-gap--path ()
  (expand-file-name ".org-museum-gap.json" org-museum-root-dir))

(defun org-museum-gap--ensure ()
  (org-museum-knowledge--ensure)
  (let ((root (file-truename org-museum-root-dir)))
    (unless (equal root org-museum-gap--root)
      (setq org-museum-gap--root root
            org-museum-gap--reports
            (alist-get 'reports
                       (org-museum-knowledge--read-json
                        (org-museum-gap--path)))))))

(defun org-museum-gap--persist ()
  (org-museum-knowledge--write-json
   (org-museum-gap--path)
   `((schemaVersion . 1) (reports . ,(vconcat org-museum-gap--reports)))))

(defun org-museum-gap--replace (report)
  (setq org-museum-gap--reports
        (cons report
              (cl-remove (alist-get 'id report) org-museum-gap--reports
                         :key (lambda (item) (alist-get 'id item))
                         :test #'equal)))
  (org-museum-gap--persist))

(defun org-museum-gap--page-score (task page anchor relations)
  (let ((id (org-museum-page-id page)))
    (+ (* 3 (org-museum-knowledge--score
             task (concat (org-museum-page-title page) " "
                          (or (org-museum-page-description page) ""))))
       (if (and anchor (equal id (org-museum-page-id anchor))) 12 0)
       (if (and anchor
                (or (member id (org-museum-page-links-to anchor))
                    (member id (org-museum-page-linked-from anchor)))) 3 0)
       (if anchor
           (org-museum-knowledge--relation-boost
            (org-museum-knowledge--relation-between
             (org-museum-page-id anchor) id relations)) 0))))

(defun org-museum-gap--scope (task &optional anchor)
  "Return only sources relevant to TASK and optional current ANCHOR."
  (org-museum-gap--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let ((relations (org-museum-knowledge--effective-relations)) ranked)
    (maphash
     (lambda (_id page)
       (let ((score (org-museum-gap--page-score task page anchor relations)))
         (when (> score 0) (push (cons score page) ranked))))
     (org-museum-index-pages org-museum--index))
    (setq ranked
          (sort ranked (lambda (a b)
                         (if (= (car a) (car b))
                             (string< (org-museum-page-id (cdr a))
                                      (org-museum-page-id (cdr b)))
                           (> (car a) (car b))))))
    (let ((pages (mapcar #'cdr (seq-take ranked org-museum-gap-max-pages))))
      (when (and anchor (not (memq anchor pages)))
        (setq pages (cons anchor (seq-take pages (1- org-museum-gap-max-pages)))))
      (list :task task :anchor anchor :pages pages :relations relations))))

(defun org-museum-gap--has-recorded-result-p (file)
  "Detect a saved result, without treating it as proof of this task."
  (and (file-regular-p file)
       (with-temp-buffer
         (insert-file-contents file)
         (org-museum-knowledge--recorded-result-p (buffer-string)))))

(defun org-museum-gap--experience-for-page (page-id &optional task)
  (cl-remove-if-not
   (lambda (item)
     (and (equal page-id (alist-get 'pageId item))
          (eq (alist-get 'published item) t)
          (org-museum-knowledge--experience-current-p item)
          (or (null task)
              (> (org-museum-knowledge--experience-score task item) 0))))
   org-museum-knowledge--experiences))

(defun org-museum-gap--derived-for-page (page-id &optional task)
  (org-museum-derived--ensure)
  (cl-remove-if-not
   (lambda (item)
     (and (org-museum-derived--confirmed-p item)
          (cl-find page-id (alist-get 'sources item)
                   :key (lambda (source) (alist-get 'pageId source))
                   :test #'equal)
          (or (null task)
              (> (org-museum-knowledge--score
                  task (concat (or (alist-get 'task item) "") " "
                               (or (alist-get 'claim item) ""))) 0))))
   org-museum-derived--items))

(defun org-museum-gap--observation (page relations)
  "Describe observable maturity and reuse signals for PAGE."
  (let* ((id (org-museum-page-id page))
         (file (org-museum-page-path page))
         (experiences (org-museum-gap--experience-for-page id))
         (derived (org-museum-gap--derived-for-page id))
         (links (+ (length (org-museum-page-links-to page))
                   (length (org-museum-page-linked-from page))))
         (relation-count
          (cl-count-if
           (lambda (item)
             (or (equal id (alist-get 'sourcePageId item))
                 (equal id (alist-get 'targetPageId item)))) relations))
         (recorded (org-museum-gap--has-recorded-result-p file))
         (verified (or recorded
                       (cl-some (lambda (item)
                                  (equal (alist-get 'verification item)
                                         "recorded-result")) experiences)
                       (cl-some #'org-museum-derived--verified-current-p
                                derived)))
         (reuse (+ (length experiences) (length derived)))
         (maturity (cond ((and verified (> reuse 0)) "有依据且可复用")
                         (verified "有记录依据")
                         ((> reuse 0) "有确认经验，待验证")
                         ((> (+ links relation-count) 0) "已连接")
                         (t "仅原文"))))
    `((pageId . ,id) (title . ,(org-museum-page-title page))
      (file . ,file) (hash . ,(org-museum-knowledge--file-hash file))
      (links . ,links) (relations . ,relation-count)
      (recordedResult . ,(and recorded t))
      (confirmedCases . ,(length experiences))
      (failurePatterns . ,(cl-count-if
                           #'org-museum-knowledge--failure-p experiences))
      (derivedClaims . ,(length derived))
      (verified . ,(and verified t)) (maturity . ,maturity)
      (reuseSignal . ,(cond ((and verified (> reuse 0)) "已有可复用结果")
                            ((> reuse 0) "已有确认内容，待验证")
                            ((> (length (org-museum-page-linked-from page)) 0)
                             "被其他笔记引用，待观察任务复用")
                            (t "尚无实际复用记录"))))))

(defun org-museum-gap--observations (scope)
  (mapcar (lambda (page)
            (org-museum-gap--observation
             page (plist-get scope :relations)))
          (plist-get scope :pages)))

(defun org-museum-gap--task-troubleshooting-p (task)
  (let ((case-fold-search t))
    (string-match-p
     "错误\\|失败\\|故障\\|排错\\|调试\\|报错\\|error\\|fail\\|debug\\|bug"
     task)))

(defun org-museum-gap--local-findings (scope observations)
  "Give a few task-scoped, source-backed review prompts, not facts."
  (let* ((task (plist-get scope :task))
         (pages (plist-get scope :pages))
         (ids (mapcar #'org-museum-page-id pages))
         (matching-cases
          (cl-loop for id in ids append
                   (org-museum-gap--experience-for-page id task)))
         (matching-derived
          (cl-loop for id in ids append
                   (org-museum-gap--derived-for-page id task)))
         (conflicts
          (cl-remove-if-not
           (lambda (entry)
             (let ((first (cadr entry)))
               (if (eq (car entry) 'divergent-fixes)
                   (member (alist-get 'pageId first) ids)
                 (or (member (alist-get 'sourcePageId first) ids)
                     (member (alist-get 'targetPageId first) ids)))))
           (org-museum-knowledge--conflicts
            (plist-get scope :relations))))
         findings)
    (cond
     ((null pages)
      (push `((kind . "source")
              (need . "当前任务在索引标题与摘要中缺少明确入口")
              (basis . "局部索引匹配为零；这不等于全库没有相关正文。")
              (next . "检索原文，或选定一篇起始笔记后再查看缺口。")
              (sourceIds . nil)) findings))
     (t
      (when conflicts
        (push `((kind . "conflict")
                (need . "相关知识存在待复核的相反关系或不同解法")
                (basis . ,(format "局部发现 %d 组可能冲突；尚未自动判定真伪。"
                                  (length conflicts)))
                (next . "打开语义关系视图，核对原文和适用范围。")
                (sourceIds . ,ids)) findings))
      (unless (cl-some (lambda (item)
                         (alist-get 'verified item)) observations)
        (push `((kind . "verification")
                (need . "当前相关笔记缺少可定位的验证记录")
                (basis . "局部来源未见已保存的执行结果或已验证经验。")
                (next . "在适用笔记保存执行结果，或记录实际验证来源。")
                (sourceIds . ,(seq-take ids 2))) findings))
      (unless (or matching-cases matching-derived)
        (push `((kind . "reuse")
                (need . "当前任务尚无匹配的已确认解决经验")
                (basis . "局部已确认经验与派生结论没有命中当前任务。")
                (next . "完成任务后用结算命令记录真实结果。")
                (sourceIds . ,(seq-take ids 2))) findings))
      (when (and (org-museum-gap--task-troubleshooting-p task)
                 (not (cl-some #'org-museum-knowledge--failure-p
                               matching-cases)))
        (push `((kind . "failure")
                (need . "尚无匹配的历史失败模式")
                (basis . "当前任务是排错类问题，局部来源未见已确认失败模式。")
                (next . "若本轮出现失败尝试，结算时保存原因与修复依据。")
                (sourceIds . ,(seq-take ids 2))) findings))))
    (seq-take (nreverse findings) 4)))

(defun org-museum-gap--report-id (task observations)
  (secure-hash
   'sha256
   (concat task "\n"
           (mapconcat (lambda (item)
                        (concat (alist-get 'pageId item) ":"
                                (alist-get 'hash item)))
                      observations "\n"))))

(defun org-museum-gap--report-current-p (report)
  (cl-every
   (lambda (source)
     (let ((file (alist-get 'file source)))
       (and (stringp file) (file-regular-p file)
            (equal (alist-get 'hash source)
                   (org-museum-knowledge--file-hash file)))))
   (alist-get 'sources report)))

(defun org-museum-gap--report (task observations)
  (org-museum-gap--ensure)
  (let ((id (org-museum-gap--report-id task observations))
        (ids (mapcar (lambda (item) (alist-get 'pageId item)) observations)))
    (or (cl-find id org-museum-gap--reports
                 :key (lambda (item) (alist-get 'id item)) :test #'equal)
        (cl-find-if
         (lambda (report)
           (and (equal task (alist-get 'task report))
                (equal ids
                       (mapcar (lambda (source)
                                 (alist-get 'pageId source))
                               (alist-get 'sources report)))))
         org-museum-gap--reports))))

(defvar org-museum-gap-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'org-museum-knowledge-gap-ai)
    (define-key map (kbd "g") #'org-museum-gap-refresh)
    map))

(define-derived-mode org-museum-gap-mode special-mode "知识缺口"
  "A local task gap view.  Buttons open the original notes.")

(defun org-museum-gap--render ()
  (let* ((anchor (and org-museum-gap--anchor-id
                      (gethash org-museum-gap--anchor-id
                               (org-museum-index-pages org-museum--index))))
         (scope (org-museum-gap--scope org-museum-gap--task anchor))
         (observations (org-museum-gap--observations scope))
         (findings (org-museum-gap--local-findings scope observations))
         (report (org-museum-gap--report org-museum-gap--task observations))
         (inhibit-read-only t))
    (setq org-museum-gap--view
          (list :scope scope :observations observations :report report))
    (erase-buffer)
    (insert (format "当前任务：%s\n局部检查：%d 篇相关笔记，最多 %d 篇\n"
                    org-museum-gap--task (length observations)
                    org-museum-gap-max-pages))
    (insert "a 请 Gemma 复核缺口   g 更新局部检查   q 关闭\n\n")
    (insert "待补证据（局部观察）\n")
    (if findings
        (cl-loop for item in findings for i from 1
                 do (insert (format "%d. %s\n   依据：%s\n   建议：%s\n"
                                    i (alist-get 'need item)
                                    (alist-get 'basis item)
                                    (alist-get 'next item))))
      (insert "没有发现明确的局部缺口；仍需结合实际任务判断。\n"))
    (insert "\n知识成熟度与复用线索（仅基于已有记录）\n")
    (dolist (item observations)
      (let ((file (alist-get 'file item)))
        (insert-text-button
         (format "%s · %s · %s"
                 (alist-get 'title item) (alist-get 'maturity item)
                 (alist-get 'reuseSignal item))
         'follow-link t
         'action (lambda (_button) (find-file-other-window file)))
        (insert (format "\n   连接 %d · 已确认经验 %d · 失败模式 %d · 派生结论 %d · 来源 Hash %s\n"
                        (+ (alist-get 'links item)
                           (alist-get 'relations item))
                        (alist-get 'confirmedCases item)
                        (alist-get 'failurePatterns item)
                        (alist-get 'derivedClaims item)
                        (alist-get 'hash item)))))
    (when report
      (insert (format "\n模型复核 · %s · %s\n"
                      (alist-get 'status report)
                      (or (alist-get 'model report) "未知模型")))
      (when-let* ((failure (alist-get 'error report)))
        (insert (format "待处理：%s\n" failure)))
      (if (not (org-museum-gap--report-current-p report))
          (insert "来源已变化；模型建议暂停显示，请重新检查。\n")
        (dolist (gap (alist-get 'gaps report))
          (insert (format "· %s\n  推断依据：%s\n  验证方法：%s\n  引用来源：%s\n"
                          (alist-get 'need gap) (alist-get 'why gap)
                          (alist-get 'validation gap)
                          (mapconcat #'identity
                                     (alist-get 'source_ids gap) ", "))))))
    (insert "\n模型建议仅供核对，不自动创建笔记或公开。\n")
    (goto-char (point-min))))

;;;###autoload
(defun org-museum-knowledge-gap (task)
  "Show only knowledge gaps relevant to TASK and the current Museum note."
  (interactive
   (list (read-string "当前任务/学习目标："
                      (or (thing-at-point 'sentence t) ""))))
  (unless (and (stringp task) (not (string-empty-p (string-trim task))))
    (user-error "请填写当前任务"))
  (org-museum-gap--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let ((anchor (and (buffer-file-name)
                     (org-museum--file-in-project-p (buffer-file-name))
                     (org-museum-knowledge--page-for-file
                      (buffer-file-name)))))
    (with-current-buffer (get-buffer-create "*Org Museum 知识缺口*")
      (org-museum-gap-mode)
      (setq org-museum-gap--task (string-trim task)
            org-museum-gap--anchor-id (and anchor (org-museum-page-id anchor)))
      (org-museum-gap--render)
      (display-buffer (current-buffer)))))

(defun org-museum-gap-refresh ()
  "Refresh the current task gap from the local index and private records."
  (interactive)
  (unless org-museum-gap--task
    (user-error "请先打开任务知识缺口视图"))
  (org-museum-index-build)
  (org-museum-gap--render))

(defun org-museum-gap--model-prompt (scope observations)
  "Build a bounded, source-backed prompt for one task."
  (concat
   "Current task: " (plist-get scope :task) "\n"
   "The following is a local evidence snapshot, not a complete library scan.\n\n"
   (mapconcat
    (lambda (item)
      (let* ((file (alist-get 'file item))
             (passage (org-museum-derived--best-excerpt
                       file (plist-get scope :task))))
        (format
         "Source ID: %s\nTitle: %s\nSHA-256: %s\nLinks: %d\nConfirmed cases: %d\nRecorded result present: %s\nExcerpt at line %d:\n%s"
         (alist-get 'pageId item) (alist-get 'title item)
         (alist-get 'hash item) (alist-get 'links item)
         (alist-get 'confirmedCases item)
         (if (alist-get 'recordedResult item) "yes, relevance unverified" "no")
         (cdr passage)
         (truncate-string-to-width
          (car passage) org-museum-gap-model-source-limit nil nil "…"))))
    observations "\n\n")))

(defun org-museum-gap--parse-response (response allowed-ids)
  "Parse at most three model suggestions with only known source IDs."
  (let* ((text (string-trim response))
         (body (if (string-match
                    "\\`[[:space:]]*```\\(?:json\\)?[[:space:]]*\\(\\(?:.\\|\n\\)*?\\)[[:space:]]*```[[:space:]]*\\'"
                    text)
                   (match-string 1 text) text))
         (json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (json-false nil)
         (data (condition-case nil (json-read-from-string body)
                 (error nil)))
         (gaps (alist-get 'gaps data)))
    (unless (and (assq 'gaps data) (listp gaps) (<= (length gaps) 3))
      (error "模型未返回符合要求的知识缺口列表"))
    (dolist (gap gaps)
      (let ((ids (alist-get 'source_ids gap)))
        (unless (and (cl-every (lambda (key)
                                (let ((value (alist-get key gap)))
                                  (and (stringp value)
                                       (not (string-empty-p (string-trim value)))
                                       (<= (length value) 1500))))
                              '(need why validation))
                     (listp ids)
                     (cl-every (lambda (id)
                                 (and (stringp id) (member id allowed-ids)))
                               ids))
          (error "模型建议缺少可用内容，或引用了未知来源"))))
    gaps))

(defun org-museum-gap--finish (request response status)
  (when (eq request org-museum-gap--active)
    (setq org-museum-gap--active nil)
    (when (buffer-live-p org-museum-gap--request-buffer)
      (kill-buffer org-museum-gap--request-buffer))
    (setq org-museum-gap--request-buffer nil)
    (condition-case err
        (progn
          (unless (stringp response)
            (error "知识缺口复核失败：%s" status))
          (unless (org-museum-gap--report-current-p request)
            (error "原文已变化，请刷新知识缺口后重试"))
          (setf (alist-get 'gaps request)
                (org-museum-gap--parse-response
                 response (mapcar (lambda (source)
                                    (alist-get 'pageId source))
                                  (alist-get 'sources request)))
                (alist-get 'status request) "ai-inference"
                (alist-get 'error request) nil)
          (org-museum-gap--ensure)
          (org-museum-gap--replace request)
          (when-let* ((buffer (get-buffer "*Org Museum 知识缺口*")))
            (with-current-buffer buffer
              (when (equal org-museum-gap--task
                           (alist-get 'task request))
                (org-museum-gap--render)))))
      (error (org-museum-gap--hold request (error-message-string err))))))

(defun org-museum-gap--hold (request reason)
  (setq org-museum-gap--active nil)
  (setf (alist-get 'status request) "pending-model"
        (alist-get 'error request) reason)
  (org-museum-gap--ensure)
  (org-museum-gap--replace request)
  (when-let* ((buffer (get-buffer "*Org Museum 知识缺口*")))
    (with-current-buffer buffer
      (when (equal org-museum-gap--task (alist-get 'task request))
        (org-museum-gap--render))))
  (message "Org Museum：%s；复核任务已保留，可重试" reason))

(defun org-museum-gap--send-request (request prompt)
  (let ((backend (org-museum-knowledge--backend))
        (model (org-museum-knowledge--model)))
    (setf (alist-get 'backend request)
          (or org-museum-knowledge--cloud-backend "LM Studio"))
    (setf (alist-get 'model request) model)
    ;; Adding alist keys may replace its head cons; keep the active identity.
    (setq org-museum-gap--active request)
    (setq org-museum-gap--request-buffer
          (generate-new-buffer " *org-museum-gap-request*"))
    (with-current-buffer org-museum-gap--request-buffer
      (let ((gptel-backend backend)
            (gptel-model (intern model))
            (gptel-use-context nil)
            (gptel-use-tools nil)
            (url-proxy-services
             (if org-museum-knowledge--cloud-backend url-proxy-services
               '(("no_proxy" . "127\\.0\\.0\\.1\\|localhost"))))
            (gptel-prompt-transform-functions nil))
        (gptel-request
         prompt
         :system
         (concat "针对当前任务，结合提供的原文片段和观察，指出最多三个重要的知识或证据缺口。"
                 "不能因为提供的片段没有提到某事，就断言整个知识库都没有。"
                 "不得编造引用、结果或事实；证据不足时返回空 gaps 数组。"
                 "只返回 JSON，键名保持如下英文，但字段内容使用自然、简洁的中文："
                 "{\"gaps\":[{\"need\":string,\"why\":string,"
                 "\"validation\":string,\"source_ids\":[known source IDs]}]}. "
                 "SQL、代码、字段名和函数名可保留原文。每条建议都标记为尚未验证。")
         :stream nil
         :callback (lambda (response info)
                     (unless (and (consp response)
                                  (eq (car response) 'reasoning))
                       (org-museum-gap--finish
                        request response (plist-get info :status)))))))))

(defun org-museum-gap--preflight (request prompt)
  "Require the selected local model to be loaded, with no cloud fallback."
  (if org-museum-knowledge--cloud-backend
      (org-museum-gap--send-request request prompt)
    (let ((url-proxy-services '(("no_proxy" . "127\\.0\\.0\\.1\\|localhost"))))
      (url-retrieve
       (format "http://%s/api/v1/models" org-museum-knowledge-local-host)
       (lambda (status)
         (unwind-protect
             (when (eq request org-museum-gap--active)
               (condition-case err
                   (progn
                     (when (plist-get status :error)
                       (error "无法连接 %s 上的 LM Studio"
                              org-museum-knowledge-local-host))
                     (goto-char (point-min))
                     (unless (re-search-forward "\r?\n\r?\n" nil t)
                       (error "LM Studio 返回了无效响应"))
                     (let* ((json-object-type 'alist)
                            (json-array-type 'list)
                            (json-key-type 'symbol)
                            (data (json-read))
                            (model (cl-find
                                    org-museum-knowledge-local-model
                                    (alist-get 'models data)
                                    :key (lambda (entry) (alist-get 'key entry))
                                    :test #'equal)))
                       (unless (and model (alist-get 'loaded_instances model))
                         (error "请先在 LM Studio 中加载 %s，再按 a 重试"
                                org-museum-knowledge-local-model)))
                     (org-museum-gap--send-request request prompt))
                 (error (org-museum-gap--hold
                         request (error-message-string err)))))
           (kill-buffer (current-buffer))))
       nil t t))))

;;;###autoload
(defun org-museum-knowledge-gap-ai ()
  "Ask the explicitly selected model to review this local task gap."
  (interactive)
  (unless (and (derived-mode-p 'org-museum-gap-mode)
               org-museum-gap--task org-museum-gap--view)
    (user-error "请先打开知识缺口视图"))
  (when org-museum-gap--active
    (user-error "已有模型复核正在进行"))
  (let* ((scope (plist-get org-museum-gap--view :scope))
         (observations (plist-get org-museum-gap--view :observations))
         (old (org-museum-gap--report org-museum-gap--task observations))
         (request (or (and old
                           (equal (alist-get 'id old)
                                  (org-museum-gap--report-id
                                   org-museum-gap--task observations))
                           (org-museum-gap--report-current-p old)
                           old)
                      `((id . ,(org-museum-gap--report-id
                                org-museum-gap--task observations))
                        (task . ,org-museum-gap--task)
                        (sources . ,(mapcar
                                     (lambda (item)
                                       `((pageId . ,(alist-get 'pageId item))
                                         (file . ,(alist-get 'file item))
                                         (hash . ,(alist-get 'hash item))))
                                     observations))
                        (createdAt . ,(format-time-string "%FT%T%z"))))))
    (setq org-museum-gap--active request)
    (condition-case err
        (org-museum-gap--preflight
         request (org-museum-gap--model-prompt scope observations))
      (error (org-museum-gap--hold request (error-message-string err))))
    (when org-museum-gap--active
      (message "Gemma 正在复核当前任务的本机依据"))))

;;;###autoload
(defun org-museum-knowledge-gap-cancel ()
  "Cancel an active model review while keeping the local task view."
  (interactive)
  (setq org-museum-gap--active nil)
  (when (buffer-live-p org-museum-gap--request-buffer)
    (when (fboundp 'gptel-abort)
      (gptel-abort org-museum-gap--request-buffer))
    (kill-buffer org-museum-gap--request-buffer))
  (setq org-museum-gap--request-buffer nil)
  (message "已取消知识缺口模型复核"))

(defvar org-museum-deep-scan-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'org-museum-deep-scan-cancel)
    map))

(define-derived-mode org-museum-deep-scan-mode special-mode "全库巡检"
  "Read-only governance report for one explicit full-library scan.")

(defun org-museum-deep-scan--finding (kind title detail priority &optional file)
  `((kind . ,kind) (title . ,title) (detail . ,detail)
    (priority . ,priority) (file . ,file)))

(defun org-museum-deep-scan--has-derived-p (first-id second-id)
  (cl-some
   (lambda (item)
     (and (org-museum-derived--confirmed-p item)
          (let ((ids (mapcar (lambda (source)
                               (alist-get 'pageId source))
                             (alist-get 'sources item))))
            (and (member first-id ids) (member second-id ids)))))
   org-museum-derived--items))

(defun org-museum-deep-scan--finalize (job)
  "Build a bounded report from the complete scan snapshot."
  (org-museum-derived--ensure)
  (let* ((pages (plist-get job :pages))
         (hashes (plist-get job :hashes))
         (result-ids (plist-get job :result-ids))
         (relations (org-museum-knowledge--effective-relations))
         (conflicts (org-museum-knowledge--conflicts relations))
         (stale-relations
          (cl-remove-if #'org-museum-knowledge--relation-current-p
                        org-museum-knowledge--relations))
         (low-relations
          (cl-remove-if-not
           (lambda (item)
             (< (or (alist-get 'confidence item) 0)
                org-museum-deep-scan-low-confidence)) relations))
         (stale-experiences
          (cl-remove-if #'org-museum-knowledge--experience-current-p
                        org-museum-knowledge--experiences))
         (stale-analyses
          (cl-remove-if
           (lambda (item)
             (let ((file (alist-get 'file item)))
               (and (stringp file) (file-regular-p file)
                    (equal (alist-get 'hash item)
                           (org-museum-knowledge--file-hash file)))))
           org-museum-knowledge--analyses))
         (stale-derived
          (cl-remove-if #'org-museum-derived--current-p
                        org-museum-derived--items))
         (unverified-derived
          (cl-remove-if
           (lambda (item)
             (or (equal (alist-get 'status item) "rejected")
                 (org-museum-derived--verified-current-p item)))
           org-museum-derived--items))
         (dirty
          (cl-remove-if-not
           (lambda (item)
             (member (alist-get 'status item) '("dirty" "failed")))
           org-museum-knowledge--queue))
         (page-table (org-museum-index-pages org-museum--index))
         (isolated nil) (unverified-hubs nil) (pair-seen (make-hash-table :test 'equal))
         (combinations nil) (duplicates nil) (findings nil))
    (maphash (lambda (_hash group)
               (when (> (length group) 1)
                 (push group duplicates))) hashes)
    (dolist (page pages)
      (let* ((id (org-museum-page-id page))
             (links (append (org-museum-page-links-to page)
                            (org-museum-page-linked-from page)))
             (related
              (cl-some (lambda (relation)
                         (or (equal id (alist-get 'sourcePageId relation))
                             (equal id (alist-get 'targetPageId relation))))
                       relations)))
        (when (and (null links) (not related))
          (push page isolated))
        (when (and (>= (length (org-museum-page-linked-from page)) 2)
                   (not (gethash id result-ids))
                   (null (org-museum-gap--experience-for-page id)))
          (push page unverified-hubs))
        (dolist (target-id links)
          (let* ((target (gethash target-id page-table))
                 (key (and target
                           (mapconcat #'identity
                                      (sort (list id target-id) #'string<)
                                      "|"))))
            (when (and target key (not (gethash key pair-seen)))
              (puthash key t pair-seen)
              (when (and (or (gethash id result-ids)
                             (org-museum-gap--experience-for-page id))
                         (or (gethash target-id result-ids)
                             (org-museum-gap--experience-for-page target-id))
                         (not (org-museum-deep-scan--has-derived-p
                               id target-id)))
                (push (list page target) combinations)))))))
    (dolist (group duplicates)
      (push (org-museum-deep-scan--finding
             "duplicate" "内容完全相同的笔记"
             (mapconcat #'org-museum-page-title group " / ") 8
             (org-museum-page-path (car group))) findings))
    (dolist (entry (seq-take conflicts 3))
      (push (org-museum-deep-scan--finding
             "conflict" "可能冲突的关系或解法"
             (format "%s；请核对来源与适用范围" (car entry)) 9
             (alist-get 'sourceFile (cadr entry))) findings))
    (dolist (page (seq-take unverified-hubs 4))
      (push (org-museum-deep-scan--finding
             "gap" "被多篇笔记引用，但缺记录依据"
             (org-museum-page-title page) 7
             (org-museum-page-path page)) findings))
    (dolist (pair (seq-take combinations 4))
      (push (org-museum-deep-scan--finding
             "combination" "可能值得组合的已有知识"
             (format "%s + %s；仅作人工审阅线索"
                     (org-museum-page-title (car pair))
                     (org-museum-page-title (cadr pair))) 5
             (org-museum-page-path (car pair))) findings))
    (dolist (page (seq-take isolated 3))
      (push (org-museum-deep-scan--finding
             "isolation" "尚无已索引连接的笔记"
             (org-museum-page-title page) 3
             (org-museum-page-path page)) findings))
    (when stale-relations
      (push (org-museum-deep-scan--finding
             "stale" "私有关系来源已变化"
             (format "%d 条关系已暂停用于召回" (length stale-relations)) 8)
            findings))
    (when stale-experiences
      (push (org-museum-deep-scan--finding
             "stale" "经验来源已变化"
             (format "%d 条经验需重新核对" (length stale-experiences)) 8)
            findings))
    (when stale-derived
      (push (org-museum-deep-scan--finding
             "stale" "派生结论来源已变化"
             (format "%d 条候选已暂停召回" (length stale-derived)) 8)
            findings))
    (when stale-analyses
      (push (org-museum-deep-scan--finding
             "stale" "AI 分析来源已变化"
             (format "%d 篇分析需重新生成" (length stale-analyses)) 6)
            findings))
    (when low-relations
      (push (org-museum-deep-scan--finding
             "low-confidence" "低置信语义关系"
             (format "%d 条关系建议复核" (length low-relations)) 5)
            findings))
    (when unverified-derived
      (push (org-museum-deep-scan--finding
             "unverified" "派生结论缺实际验证"
             (format "%d 条非否决候选尚无当前执行依据"
                     (length unverified-derived)) 6)
            findings))
    (when dirty
      (push (org-museum-deep-scan--finding
             "dirty" "遗留待分析或失败任务"
             (format "%d 个队列项需要按需处理" (length dirty)) 4)
            findings))
    (dolist (missing (plist-get job :missing))
      (push (org-museum-deep-scan--finding
             "missing" "索引指向已不存在的来源"
             missing 10) findings))
    (list :scanned (length pages)
          :generated-at (format-time-string "%FT%T%z")
          :counts
          `((duplicates . ,(length duplicates))
            (conflicts . ,(length conflicts))
            (isolated . ,(length isolated))
            (staleRelations . ,(length stale-relations))
            (staleExperiences . ,(length stale-experiences))
            (staleAnalyses . ,(length stale-analyses))
            (staleDerived . ,(length stale-derived))
            (lowConfidence . ,(length low-relations))
            (combinations . ,(length combinations))
            (unverifiedDerived . ,(length unverified-derived))
            (unverifiedHubs . ,(length unverified-hubs))
            (dirty . ,(length dirty))
            (missing . ,(length (plist-get job :missing))))
          :findings (seq-take
                     (sort findings
                           (lambda (a b)
                             (if (= (alist-get 'priority a)
                                    (alist-get 'priority b))
                                 (string< (alist-get 'title a)
                                          (alist-get 'title b))
                               (> (alist-get 'priority a)
                                  (alist-get 'priority b))))) 12))))

(defun org-museum-deep-scan--render (&optional cancelled)
  (with-current-buffer (get-buffer-create "*Org Museum 深度巡检*")
    (org-museum-deep-scan-mode)
    (let ((inhibit-read-only t)
          (job org-museum-deep-scan--job)
          (report org-museum-deep-scan--last-report))
      (erase-buffer)
      (cond
       (job
        (insert (format "全库治理扫描中：%d/%d 篇\n"
                        (plist-get job :position)
                        (length (plist-get job :pages))))
        (insert "扫描只读取原文与私有派生层；按 c 可取消。\n"))
       (cancelled
        (insert "全库治理扫描已取消；原文与派生层未改动。\n"))
       (report
        (let ((counts (plist-get report :counts)))
          (insert (format "全库治理完成：%d 篇 · %s\n"
                          (plist-get report :scanned)
                          (plist-get report :generated-at)))
          (insert (format
                   "重复 %d · 冲突 %d · 孤立 %d · 失效 %d · 低置信 %d · 可组合 %d · 未验证 %d · 待分析 %d\n"
                   (alist-get 'duplicates counts)
                   (alist-get 'conflicts counts)
                   (alist-get 'isolated counts)
                   (+ (alist-get 'staleRelations counts)
                      (alist-get 'staleExperiences counts)
                      (alist-get 'staleAnalyses counts)
                      (alist-get 'staleDerived counts))
                   (alist-get 'lowConfidence counts)
                   (alist-get 'combinations counts)
                   (alist-get 'unverifiedDerived counts)
                   (alist-get 'dirty counts)))
          (insert "\n优先审阅（仅显示前 12 项）\n")
          (if (null (plist-get report :findings))
              (insert "未发现明确的治理事项。\n")
            (cl-loop for item in (plist-get report :findings)
                     for number from 1
                     do (let ((file (alist-get 'file item)))
                          (if (and file (file-regular-p file))
                              (insert-text-button
                               (format "%d. %s" number
                                       (alist-get 'title item))
                               'follow-link t
                               'action (lambda (_button)
                                         (find-file-other-window file)))
                            (insert (format "%d. %s" number
                                            (alist-get 'title item))))
                          (insert (format "：%s\n"
                                          (alist-get 'detail item))))))
          (insert "\n这些是治理线索，未自动判断真伪或修改原文。\n")))
       (t (insert "尚未运行全库治理扫描。\n")))
      (goto-char (point-min)))
    (display-buffer (current-buffer))))

(defun org-museum-deep-scan--step ()
  "Read one bounded batch, then yield back to Emacs."
  (setq org-museum-deep-scan--timer nil)
  (when org-museum-deep-scan--job
    (let* ((job org-museum-deep-scan--job)
           (pages (plist-get job :pages))
           (start (plist-get job :position))
           (end (min (length pages)
                     (+ start (max 1 org-museum-deep-scan-batch-size)))))
      (cl-loop for index from start below end
               for page = (nth index pages)
               for file = (org-museum-page-path page)
               do (if (not (file-regular-p file))
                      (push file (plist-get job :missing))
                    (let* ((hash (org-museum-knowledge--file-hash file))
                           (group (gethash hash (plist-get job :hashes))))
                      (puthash hash (cons page group)
                               (plist-get job :hashes))
                       (when (org-museum-gap--has-recorded-result-p file)
                         (puthash (org-museum-page-id page) t
                                  (plist-get job :result-ids))))))
      (setf (plist-get job :position) end)
      (if (< end (length pages))
          (progn
            (org-museum-deep-scan--render)
            (setq org-museum-deep-scan--timer
                  (run-at-time 0.05 nil #'org-museum-deep-scan--step)))
        (setq org-museum-deep-scan--last-report
              (org-museum-deep-scan--finalize job)
              org-museum-deep-scan--job nil)
        (org-museum-deep-scan--render)
        (message "Org Museum 全库巡检完成：%d 篇笔记"
                 (length pages))))))

;;;###autoload
(defun org-museum-deep-scan ()
  "Explicitly scan the entire wiki for reviewable governance findings.
The scan is read-only, model-free, batched, and cancellable."
  (interactive)
  (when org-museum-deep-scan--job
    (user-error "全库巡检已在进行中"))
  (org-museum-gap--ensure)
  (org-museum-derived--ensure)
  (org-museum-index-build t)
  (let (pages)
    (maphash (lambda (_id page) (push page pages))
             (org-museum-index-pages org-museum--index))
    (setq pages (sort pages (lambda (a b)
                              (string< (org-museum-page-id a)
                                       (org-museum-page-id b)))))
    (setq org-museum-deep-scan--last-report nil
          org-museum-deep-scan--job
          (list :pages pages :position 0
                :hashes (make-hash-table :test 'equal)
                :result-ids (make-hash-table :test 'equal)
                :missing nil))
    (org-museum-deep-scan--render)
    (setq org-museum-deep-scan--timer
          (run-at-time 0 nil #'org-museum-deep-scan--step))))

;;;###autoload
(defun org-museum-deep-scan-cancel ()
  "Cancel a pending Deep Scan without changing any knowledge records."
  (interactive)
  (when (timerp org-museum-deep-scan--timer)
    (cancel-timer org-museum-deep-scan--timer))
  (setq org-museum-deep-scan--timer nil
        org-museum-deep-scan--job nil)
  (org-museum-deep-scan--render t))

;;;###autoload
(defun org-museum-deep-scan-status ()
  "Display progress or the latest Deep Scan report."
  (interactive)
  (org-museum-deep-scan--render))

(provide 'org-museum-gap)
;;; org-museum-gap.el ends here
