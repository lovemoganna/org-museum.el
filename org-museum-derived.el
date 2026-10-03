;;; org-museum-derived.el --- Reviewable knowledge combinations -*- lexical-binding: t -*-

;; Loaded after the Org Museum index, knowledge runtime and context graph.
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup org-museum-derived nil
  "Private, source-backed knowledge combinations."
  :group 'org-museum-knowledge)

(defcustom org-museum-derived-source-limit 1800
  "Maximum characters from each source sent to the selected model."
  :type 'integer :group 'org-museum-derived)

(defvar org-museum-derived--root nil)
(defvar org-museum-derived--items nil)
(defvar org-museum-derived--active nil)
(defvar org-museum-derived--request-buffer nil)
(defvar-local org-museum-derived--selected-id nil)

(defun org-museum-derived--path ()
  (expand-file-name ".org-museum-derived.json" org-museum-root-dir))

(defun org-museum-derived--ensure ()
  (org-museum-knowledge--ensure)
  (let ((root (file-truename org-museum-root-dir)))
    (unless (equal root org-museum-derived--root)
      (setq org-museum-derived--root root
            org-museum-derived--items
            (alist-get 'items
                       (org-museum-knowledge--read-json
                        (org-museum-derived--path)))))))

(defun org-museum-derived--persist ()
  (org-museum-knowledge--write-json
   (org-museum-derived--path)
   `((schemaVersion . 1) (items . ,(vconcat org-museum-derived--items)))))

(defun org-museum-derived--replace (item)
  "Persist ITEM, including newly added alist fields."
  (setq org-museum-derived--items
        (cons item
              (cl-remove (alist-get 'id item) org-museum-derived--items
                         :key (lambda (entry) (alist-get 'id entry))
                         :test #'equal)))
  (org-museum-derived--persist))

(defun org-museum-derived--best-excerpt (file task)
  "Choose a short source passage near the task's strongest matching line."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((best-point nil) (best-score 0) (first-content nil))
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((start (point))
               (line (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position)))
               (score (org-museum-knowledge--score task line)))
          (unless (or first-content
                      (string-empty-p (string-trim line))
                      (string-prefix-p "#+" line))
            (setq first-content start))
          (when (and (not (string-prefix-p "#+" line))
                     (> score best-score))
            (setq best-score score best-point start)))
        (forward-line 1))
      (goto-char (or best-point first-content (point-min)))
      (let* ((start (point))
             (line (line-number-at-pos start))
             (end (min (point-max) (+ start org-museum-derived-source-limit))))
        (cons (string-trim (buffer-substring-no-properties start end)) line)))))

(defun org-museum-derived--choose-target-page (task)
  "Offer indexed source notes, with linked and task-relevant notes first."
  (let* ((current (org-museum-knowledge--page-for-file (buffer-file-name)))
         (relations (org-museum-knowledge--effective-relations))
         choices)
    (maphash
     (lambda (id page)
       (unless (equal id (org-museum-page-id current))
         (let ((score (+ (org-museum-knowledge--score
                          task (concat (org-museum-page-title page) " "
                                       (or (org-museum-page-description page) "")))
                         (if (or (member id (org-museum-page-links-to current))
                                 (member id (org-museum-page-linked-from current)))
                             3 0)
                         (org-museum-knowledge--relation-boost
                          (org-museum-knowledge--relation-between
                           (org-museum-page-id current) id relations)))))
           (push (list score
                       (format "%s [%s]" (org-museum-page-title page) id)
                       id) choices))))
     (org-museum-index-pages org-museum--index))
    (let* ((ranked (sort choices
                         (lambda (a b)
                           (if (= (car a) (car b))
                               (string< (cadr a) (cadr b))
                             (> (car a) (car b))))))
           (labels (mapcar #'cadr ranked)))
      (unless labels (user-error "没有其他可选的已索引笔记"))
      (nth 2 (assoc (completing-read "组合另一篇笔记：" labels nil t)
                    (mapcar (lambda (item)
                              (list (cadr item) (car item) (nth 2 item)))
                            ranked))))))

(defun org-museum-derived--source (page &optional selected task)
  "Capture PAGE's current version and an exact excerpt.
SELECTED is an explicit region in the current source note."
  (let* ((file (org-museum-page-path page))
         (passage (unless selected
                    (org-museum-derived--best-excerpt file task)))
         (excerpt (string-trim (or selected (car passage))))
         (line (if selected
                   (line-number-at-pos (region-beginning)) (cdr passage))))
    (when (> (length excerpt) org-museum-derived-source-limit)
      (user-error "请选择不超过 %d 字的原文片段"
                  org-museum-derived-source-limit))
    (when (string-empty-p excerpt)
      (user-error "原笔记没有可供组合的内容"))
    `((pageId . ,(org-museum-page-id page))
      (title . ,(org-museum-page-title page))
      (file . ,file)
      (hash . ,(org-museum-knowledge--file-hash file))
      (line . ,line)
      (excerpt . ,excerpt)
      (excerptHash . ,(secure-hash 'sha256 excerpt)))))

(defun org-museum-derived--current-p (item)
  "Return non-nil only while both original source versions still match."
  (let ((sources (alist-get 'sources item)))
    (and (= (length sources) 2)
         (cl-every
          (lambda (source)
            (let ((file (alist-get 'file source)))
              (and (stringp file) (file-regular-p file)
                   (equal (alist-get 'hash source)
                          (org-museum-knowledge--file-hash file)))))
          sources))))

(defun org-museum-derived--confirmed-p (item)
  (and (member (alist-get 'status item) '("user-confirmed" "recorded-result"))
       (org-museum-derived--current-p item)))

(defun org-museum-derived--source-summary (source)
  (format "%s · %s:%d · SHA-256 %s"
          (alist-get 'title source) (alist-get 'file source)
          (alist-get 'line source) (alist-get 'hash source)))

(defun org-museum-derived--response-json (response)
  "Parse one model proposal; reject malformed or empty claims."
  (let* ((text (string-trim response))
         (body (if (string-match
                    "\\`[[:space:]]*```\\(?:json\\)?[[:space:]]*\\(\\(?:.\\|\n\\)*?\\)[[:space:]]*```[[:space:]]*\\'"
                    text)
                   (match-string 1 text) text))
         (json-object-type 'alist)
         (json-key-type 'symbol)
         (json-false nil)
         (data (condition-case nil
                   (json-read-from-string body)
                 (error nil)))
         (claim (alist-get 'claim data))
         (why (alist-get 'why data))
         (plan (alist-get 'verification_plan data)))
    (unless (and (stringp claim) (not (string-empty-p (string-trim claim)))
                 (stringp why) (not (string-empty-p (string-trim why)))
                 (stringp plan) (not (string-empty-p (string-trim plan)))
                 (<= (length claim) 3000)
                 (<= (length why) 3000)
                 (<= (length plan) 3000))
      (error "模型未返回可用的结论、理由和验证方案"))
    (list (string-trim claim) (string-trim why) (string-trim plan))))

(defun org-museum-derived--finish (request response status)
  (when (eq request org-museum-derived--active)
    (setq org-museum-derived--active nil)
    (when (buffer-live-p org-museum-derived--request-buffer)
      (kill-buffer org-museum-derived--request-buffer))
    (setq org-museum-derived--request-buffer nil)
    (condition-case err
        (progn
          (unless (stringp response)
            (error "知识组合失败：%s" status))
          (unless (org-museum-derived--current-p request)
            (error "原文已变化，请重新组合"))
          (pcase-let ((`(,claim ,why ,plan)
                       (org-museum-derived--response-json response)))
            (setf (alist-get 'claim request) claim
                  (alist-get 'why request) why
                  (alist-get 'verificationPlan request) plan
                  (alist-get 'status request) "ai-inference")
            (org-museum-derived--ensure)
            (org-museum-derived--replace request)
            (org-museum-derived--show request)))
      (error (org-museum-derived--hold request (error-message-string err))))))

(defun org-museum-derived--hold (request reason)
  "Keep REQUEST privately available for an explicit retry."
  (setq org-museum-derived--active nil)
  (setf (alist-get 'status request) "pending-model"
        (alist-get 'error request) reason)
  (org-museum-derived--ensure)
  (org-museum-derived--replace request)
  (org-museum-derived--show request)
  (message "Org Museum：%s；组合任务已保留，可重试" reason))

(defun org-museum-derived--request (request)
  (let ((backend (org-museum-knowledge--backend))
        (model (org-museum-knowledge--model)))
    (setf (alist-get 'backend request)
          (or org-museum-knowledge--cloud-backend "LM Studio"))
    (setf (alist-get 'model request) model)
    (setq org-museum-derived--active request)
    (setq org-museum-derived--request-buffer
          (generate-new-buffer " *org-museum-derived-request*"))
    (with-current-buffer org-museum-derived--request-buffer
      (let ((gptel-backend backend)
            (gptel-model (intern model))
            (gptel-use-context nil)
            (gptel-use-tools nil)
            (url-proxy-services
             (if org-museum-knowledge--cloud-backend url-proxy-services
               '(("no_proxy" . "127\\.0\\.0\\.1\\|localhost"))))
            (gptel-prompt-transform-functions nil))
        (gptel-request
         (format "当前任务：%s\n\n来源甲 [%s]：\n%s\n\n来源乙 [%s]：\n%s"
                 (alist-get 'task request)
                 (alist-get 'title (car (alist-get 'sources request)))
                 (alist-get 'excerpt (car (alist-get 'sources request)))
                 (alist-get 'title (cadr (alist-get 'sources request)))
                 (alist-get 'excerpt (cadr (alist-get 'sources request))))
         :system
         (concat "针对当前任务，结合两段来源提出一条有用、可证伪的新结论，"
                 "不要只复述任一来源。结论属于尚未验证的假设。若证据不足，"
                 "请在结论中直说，并指出缺少的依据。只返回 JSON，键名固定为 "
                 "claim、why、verification_plan；三个字段的内容都用自然、简洁的中文。"
                 "SQL、代码、字段名和函数名可保留原文。不得编造引用、执行结果或来源事实。")
         :stream nil
         :callback (lambda (response info)
                     (unless (and (consp response)
                                  (eq (car response) 'reasoning))
                       (org-museum-derived--finish
                        request response (plist-get info :status)))))))))

(defun org-museum-derived--preflight (request)
  "Check the local model before requesting; never switch to a cloud backend."
  (if org-museum-knowledge--cloud-backend
      (org-museum-derived--request request)
    (let ((url-proxy-services '(("no_proxy" . "127\\.0\\.0\\.1\\|localhost"))))
      (url-retrieve
       (format "http://%s/api/v1/models" org-museum-knowledge-local-host)
       (lambda (status)
         (unwind-protect
             (when (eq request org-museum-derived--active)
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
                         (error "请先在 LM Studio 中加载 %s，再重试知识组合"
                                org-museum-knowledge-local-model)))
                     (org-museum-derived--request request))
                 (error
                  (org-museum-derived--hold request
                                           (error-message-string err)))))
           (kill-buffer (current-buffer))))
       nil t t))))

;;;###autoload
(defun org-museum-derive-current (task target-id &optional selected)
  "Combine this saved note with TARGET-ID for TASK on explicit request.
With a region, use that source passage.  The result remains private and
unverified until reviewed.  The original Org files are never edited."
  (interactive
   (progn
     (org-museum-knowledge--ensure)
     (unless org-museum--index (org-museum-index-build))
     (unless (and (buffer-file-name)
                  (org-museum--file-in-project-p (buffer-file-name))
                  (org-museum-knowledge--page-for-file (buffer-file-name)))
       (user-error "请先打开一篇已索引笔记"))
     (let ((task (read-string "当前问题或目标：")))
       (list task (org-museum-derived--choose-target-page task)
             (when (use-region-p)
               (buffer-substring-no-properties
                (region-beginning) (region-end)))))))
  (org-museum-derived--ensure)
  (unless (and (buffer-file-name)
               (org-museum--file-in-project-p (buffer-file-name)))
    (user-error "知识组合前请先打开已保存的笔记"))
  (when (buffer-modified-p)
    (user-error "知识组合前请先保存原笔记"))
  (when (string-empty-p (string-trim task))
    (user-error "请填写当前任务"))
  (when org-museum-derived--active
    (user-error "已有知识组合正在进行"))
  (unless org-museum--index (org-museum-index-build))
  (let* ((page (org-museum-knowledge--page-for-file (buffer-file-name)))
         (other (gethash target-id (org-museum-index-pages org-museum--index))))
    (unless (and page other (not (equal (org-museum-page-id page) target-id)))
      (user-error "请选择另一篇已索引笔记"))
    (let* ((sources (list (org-museum-derived--source page selected task)
                          (org-museum-derived--source other nil task)))
           (request `((id . ,(secure-hash
                              'sha256
                              (concat task (alist-get 'pageId (car sources))
                                      (alist-get 'pageId (cadr sources))
                                      (alist-get 'hash (car sources))
                                      (alist-get 'hash (cadr sources))
                                      (alist-get 'excerptHash (car sources)))))
                      (task . ,(string-trim task))
                      (sources . ,sources)
                      (createdAt . ,(format-time-string "%FT%T%z"))
                      (backend . ,(or org-museum-knowledge--cloud-backend
                                      "LM Studio"))
                      (model . ,(org-museum-knowledge--model)))))
      (let ((existing (cl-find (alist-get 'id request)
                               org-museum-derived--items
                               :key (lambda (item) (alist-get 'id item))
                               :test #'equal)))
        (if (and existing (org-museum-derived--confirmed-p existing))
            (org-museum-derived--show existing)
          (setq org-museum-derived--active request)
          (condition-case err
              (org-museum-derived--preflight request)
            (error (org-museum-derived--hold request
                                             (error-message-string err))))
          (when org-museum-derived--active
            (message "正在组合两篇笔记；候选生成后会打开私有预览")))))))

;;;###autoload
(defun org-museum-derived-cancel ()
  "Cancel an outstanding combination without saving a candidate."
  (interactive)
  (setq org-museum-derived--active nil)
  (when (buffer-live-p org-museum-derived--request-buffer)
    (when (fboundp 'gptel-abort)
      (gptel-abort org-museum-derived--request-buffer))
    (kill-buffer org-museum-derived--request-buffer))
  (setq org-museum-derived--request-buffer nil)
  (message "已取消知识组合"))

(defvar org-museum-derived-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'org-museum-derived-accept)
    (define-key map (kbd "r") #'org-museum-derived-reject)
    (define-key map (kbd "t") #'org-museum-derived-retry)
    (define-key map (kbd "o") #'org-museum-derived-open-source)
    map))

(define-derived-mode org-museum-derived-review-mode special-mode "知识组合"
  "Review a private derived knowledge candidate.")

(defun org-museum-derived--status-label (item)
  (pcase (alist-get 'status item)
    ("ai-inference" "AI 推断，未确认")
    ("user-confirmed" "用户确认，尚未见执行结果")
    ("recorded-result"
     (if (org-museum-derived--verified-current-p item)
         "有原笔记执行结果（未重新执行）"
       "用户确认，执行依据已变化"))
    ("pending-model" "等待模型，可重试")
    ("rejected" "已否决")
    (_ "未知")))

(defun org-museum-derived--show (item)
  (with-current-buffer (get-buffer-create "*Org Museum 派生知识*")
    (org-museum-derived-review-mode)
    (setq org-museum-derived--selected-id (alist-get 'id item))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "派生知识候选 · %s%s\n\n"
                      (org-museum-derived--status-label item)
                      (if (org-museum-derived--current-p item)
                          "" " · 来源已变化")))
      (insert (format "当前任务：%s\n\n组合结论：%s\n\n组合依据：%s\n\n验证计划：%s\n\n"
                      (alist-get 'task item)
                      (or (alist-get 'claim item) "等待生成")
                      (or (alist-get 'why item) "等待生成")
                      (or (alist-get 'verificationPlan item) "等待生成")))
      (when-let* ((failure (alist-get 'error item)))
        (insert (format "待处理：%s\n\n" failure)))
      (insert "来源与原文版本：\n")
      (cl-loop for source in (alist-get 'sources item)
               for number from 1
               do (insert (format "%d. %s\n片段：%s\n\n"
                                  number
                                  (org-museum-derived--source-summary source)
                                  (alist-get 'excerpt source))))
      (when-let* ((verification (alist-get 'verification item)))
        (insert (format "记录的验证：%s\n证据：%s:%d\n\n"
                        (alist-get 'observation verification)
                        (alist-get 'file verification)
                        (alist-get 'line verification))))
      (insert (format "模型：%s / %s；生成：%s\n"
                      (alist-get 'backend item) (alist-get 'model item)
                      (alist-get 'createdAt item)))
      (insert "\na 确认结论   r 否决   t 重试   o 打开来源   q 关闭\n")
      (insert "实际执行后，在含 #+RESULTS 的原笔记选中结果并运行 M-x org-museum-derived-verify。\n")
      (insert "候选只在私有层；不进入站点导出。\n")
      (goto-char (point-min)))
    (display-buffer (current-buffer))))

;;;###autoload
(defun org-museum-derived-review (&optional id)
  "Review a private candidate, including unconfirmed and stale entries."
  (interactive)
  (org-museum-derived--ensure)
  (unless org-museum-derived--items
    (user-error "还没有知识组合候选"))
  (let* ((chosen (or id
                     (completing-read
                      "派生知识候选："
                      (mapcar (lambda (item)
                                (cons (format "%s · %s · %s"
                                              (org-museum-derived--status-label item)
                                              (alist-get 'task item)
                                              (substring (alist-get 'id item) 0 8))
                                      (alist-get 'id item)))
                              org-museum-derived--items)
                      nil t)))
         (id (or (cdr (assoc chosen
                             (mapcar (lambda (item)
                                       (cons (format "%s · %s · %s"
                                                     (org-museum-derived--status-label item)
                                                     (alist-get 'task item)
                                                     (substring (alist-get 'id item) 0 8))
                                             (alist-get 'id item)))
                                     org-museum-derived--items)))
                 chosen))
         (item (cl-find id org-museum-derived--items
                        :key (lambda (entry) (alist-get 'id entry))
                        :test #'equal)))
    (unless item (user-error "候选已不可用"))
    (org-museum-derived--show item)))

(defun org-museum-derived--selected ()
  (org-museum-derived--ensure)
  (or (cl-find org-museum-derived--selected-id org-museum-derived--items
               :key (lambda (item) (alist-get 'id item)) :test #'equal)
      (user-error "请先选择一条知识组合候选")))

;;;###autoload
(defun org-museum-derived-retry ()
  "Retry the selected unconfirmed combination on explicit request."
  (interactive)
  (let ((item (org-museum-derived--selected)))
    (when org-museum-derived--active
      (user-error "已有知识组合正在进行"))
    (unless (org-museum-derived--current-p item)
      (user-error "原文已变化，请重新生成候选"))
    (unless (member (alist-get 'status item) '("pending-model" "ai-inference"))
      (user-error "只有未确认的候选可以重试"))
    (setq org-museum-derived--active item)
    (condition-case err
        (org-museum-derived--preflight item)
      (error (org-museum-derived--hold item (error-message-string err))))))

;;;###autoload
(defun org-museum-derived-accept ()
  "Confirm the selected claim as useful, without claiming execution proof."
  (interactive)
  (let ((item (org-museum-derived--selected)))
    (unless (org-museum-derived--current-p item)
      (user-error "原文已变化，请重新生成候选"))
    (unless (equal (alist-get 'status item) "ai-inference")
      (user-error "只有尚未审核的候选可以确认"))
    (when (yes-or-no-p "确认这条组合结论可复用（尚未执行验证）？")
      (setf (alist-get 'status item) "user-confirmed"
            (alist-get 'confirmedAt item) (format-time-string "%FT%T%z"))
      (org-museum-derived--replace item)
      (org-museum-derived--show item))))

;;;###autoload
(defun org-museum-derived-reject ()
  "Reject the selected candidate without changing its source notes."
  (interactive)
  (let ((item (org-museum-derived--selected)))
    (when (yes-or-no-p "否决这条派生知识候选？")
      (setf (alist-get 'status item) "rejected")
      (org-museum-derived--replace item)
      (org-museum-derived--show item))))

(defun org-museum-derived-open-source (&optional second)
  "Open the first source, or the second with a prefix."
  (interactive "P")
  (let* ((item (org-museum-derived--selected))
         (source (nth (if second 1 0) (alist-get 'sources item))))
    (find-file-other-window (alist-get 'file source))
    (goto-char (point-min))
    (forward-line (1- (alist-get 'line source)))))

;;;###autoload
(defun org-museum-derived-verify (id observation)
  "Attach a saved Org execution result to a confirmed candidate.
The active region must contain a nonempty #+RESULTS block.  This records
an existing result as evidence; it does not rerun the source block."
  (interactive
   (progn
     (org-museum-derived--ensure)
     (list (completing-read
            "确认的组合结论："
            (mapcar (lambda (item)
                      (cons (alist-get 'claim item) (alist-get 'id item)))
                    (cl-remove-if-not #'org-museum-derived--confirmed-p
                                      org-museum-derived--items))
            nil t)
           (read-string "实际结果说明："))))
  (org-museum-derived--ensure)
  (let* ((resolved-id (or (cdr (assoc id
                                      (mapcar (lambda (item)
                                                (cons (alist-get 'claim item)
                                                      (alist-get 'id item)))
                                              org-museum-derived--items)))
                          id))
         (item (cl-find resolved-id org-museum-derived--items
                        :key (lambda (entry) (alist-get 'id entry))
                        :test #'equal)))
    (unless (and item (org-museum-derived--confirmed-p item))
      (user-error "记录验证前请先确认来源未变化的候选"))
    (unless (and (buffer-file-name)
                 (org-museum--file-in-project-p (buffer-file-name))
                 (not (buffer-modified-p)) (use-region-p))
      (user-error "请在已保存的 Org 笔记中选择结果"))
    (when (string-empty-p (string-trim observation))
      (user-error "请描述实际观察到的结果"))
    (let* ((excerpt (buffer-substring-no-properties
                     (region-beginning) (region-end)))
           (file (expand-file-name (buffer-file-name)))
           (line (line-number-at-pos (region-beginning))))
      (unless (org-museum-knowledge--recorded-result-p excerpt)
        (user-error "所选内容必须包含非空的 #+RESULTS 结果块"))
      (when (yes-or-no-p "将这段已保存执行结果作为验证依据？")
        (unless (org-museum-derived--current-p item)
          (user-error "原文已变化，请重新生成候选"))
        (setf (alist-get 'status item) "recorded-result"
              (alist-get 'verification item)
              `((observation . ,(string-trim observation))
                (file . ,file) (line . ,line)
                (sourceHash . ,(org-museum-knowledge--file-hash file))
                (excerpt . ,excerpt)
                (excerptHash . ,(secure-hash 'sha256 excerpt))
                (recordedAt . ,(format-time-string "%FT%T%z"))))
        (org-museum-derived--replace item)
        (org-museum-derived--show item)))))

(defun org-museum-derived--verified-current-p (item)
  (let ((verification (alist-get 'verification item)))
    (and (equal (alist-get 'status item) "recorded-result")
         (org-museum-derived--current-p item)
         verification
         (file-regular-p (alist-get 'file verification))
         (equal (alist-get 'sourceHash verification)
                (org-museum-knowledge--file-hash
                 (alist-get 'file verification))))))

(defun org-museum-derived--relevant (query &optional page-id)
  "Rank current confirmed combinations for QUERY and PAGE-ID."
  (org-museum-derived--ensure)
  (sort
   (cl-loop for item in org-museum-derived--items
            for score = (if (org-museum-derived--confirmed-p item)
                            (+ (org-museum-knowledge--score
                                query (concat (alist-get 'task item) " "
                                              (alist-get 'claim item) " "
                                              (alist-get 'why item)))
                               (if (and page-id
                                        (cl-find page-id (alist-get 'sources item)
                                                 :key (lambda (source)
                                                        (alist-get 'pageId source))
                                                 :test #'equal))
                                   4 0))
                          0)
            when (> score 0)
            collect (cons score item))
   (lambda (a b) (> (car a) (car b)))))

(defun org-museum-derived--recall-text (query &optional page-id)
  "Return a private Org view of current, confirmed combinations."
  (or (mapconcat
   (lambda (scored)
     (let* ((item (cdr scored))
            (sources (alist-get 'sources item))
            (verification (alist-get 'verification item)))
       (concat
        (format "* 已确认派生知识 · 相关度 %d\n组合结论：%s\n组合依据：%s\n验证：%s\n验证计划：%s\n"
                (car scored) (alist-get 'claim item) (alist-get 'why item)
                (if (org-museum-derived--verified-current-p item)
                    "原笔记含执行结果（未重新执行）"
                  "用户确认，尚未见当前执行结果")
                (alist-get 'verificationPlan item))
        (mapconcat
         (lambda (source)
           (format "派生自：[[file:%s::%d][%s，第 %d 行]] · 来源 Hash %s\n"
                   (alist-get 'file source) (alist-get 'line source)
                   (alist-get 'title source) (alist-get 'line source)
                   (alist-get 'hash source)))
         sources "")
        (if (and verification (org-museum-derived--verified-current-p item))
            (format "执行依据：[[file:%s::%d][打开结果]] · %s\n"
                    (alist-get 'file verification)
                    (alist-get 'line verification)
                    (alist-get 'observation verification)) "")
        "\n")))
   (seq-take (org-museum-derived--relevant query page-id) 5) "") ""))

(provide 'org-museum-derived)
;;; org-museum-derived.el ends here
