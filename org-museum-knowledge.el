;;; org-museum-knowledge.el --- Incremental knowledge runtime -*- lexical-binding: t -*-

;; This file is loaded by org-museum.el after its indexing/export functions.

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)

(defvar gptel--known-backends)
(defvar gptel-model)
(defvar gptel-backend)
(defvar gptel-use-context)
(defvar gptel-use-tools)
(defvar gptel-prompt-transform-functions)
(declare-function gptel-get-backend "gptel-request" (name))
(declare-function gptel-make-openai "gptel-openai" (name &rest args))
(declare-function gptel-request "gptel-request" (&rest args))

(defgroup org-museum-knowledge nil
  "Opt-in knowledge analysis for Org Museum."
  :group 'org-museum)

(defcustom org-museum-knowledge-work-mode 'assist
  "Knowledge worker mode: manual, assist, or auto.
Only auto starts analysis without an explicit analysis command."
  :type '(choice (const manual) (const assist) (const auto))
  :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-idle-seconds 8
  "Idle time before the optional auto worker starts one job."
  :type 'number :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-max-retries 2
  "Maximum automatic retries for a failed analysis."
  :type 'integer :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-max-workers 2
  "Maximum number of concurrent note analysis requests."
  :type 'integer :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-timeout-seconds 180
  "Maximum time allowed for one note analysis request."
  :type 'number :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-local-host "127.0.0.1:1234"
  "LM Studio OpenAI-compatible host."
  :type 'string :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-local-model "google/gemma-4-e2b"
  "Local model for analysis.  It must be loaded in LM Studio."
  :type 'string :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-source-limit 16000
  "Maximum source characters sent in one analysis request."
  :type 'integer :group 'org-museum-knowledge)

(defvar org-museum-knowledge--root nil)
(defvar org-museum-knowledge--queue nil)
(defvar org-museum-knowledge--analyses nil)
(defvar org-museum-knowledge--experiences nil)
(defvar org-museum-knowledge--relations nil)
(defvar org-museum-knowledge--persist-timer nil)
(defvar org-museum-knowledge--auto-timer nil)
(defvar org-museum-knowledge--active nil)
(defvar org-museum-knowledge--request-buffer nil)
(defvar org-museum-knowledge--actives nil)
(defvar org-museum-knowledge--request-buffers nil)
(defvar org-museum-knowledge--request-timers nil)
(defvar org-museum-knowledge--batch nil)
(defvar org-museum-knowledge--batch-log nil)
(defvar org-museum-knowledge--cloud-backend nil)
(defvar org-museum-knowledge--cloud-model nil)
(defvar org-museum-knowledge--paused nil)
(defvar org-museum-knowledge--drain nil)
(defvar org-museum-knowledge--requested-file nil)
(defvar-local org-museum-knowledge--reminded nil)

(defcustom org-museum-knowledge-reminder-idle-seconds 3
  "Idle time before checking a newly opened Museum note for past failures."
  :type 'number :group 'org-museum-knowledge)

(defcustom org-museum-knowledge-reminder-min-score 2
  "Minimum text overlap required for a past failure reminder."
  :type 'integer :group 'org-museum-knowledge)

(defun org-museum-knowledge--state-path ()
  (expand-file-name ".org-museum-ai-state.json" org-museum-root-dir))

(defun org-museum-knowledge--derived-path ()
  (expand-file-name ".org-museum-knowledge.json" org-museum-root-dir))

(defun org-museum-knowledge--read-json (path)
  (when (file-regular-p path)
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'symbol)
          (json-false nil))
      (json-read-file path))))

(defun org-museum-knowledge--write-json (path value)
  (let ((json-encoding-pretty-print nil))
    (org-museum--write-content-if-changed path (json-encode value))))

(defun org-museum-knowledge--ensure ()
  "Load private state for the active wiki, once per root."
  (unless (and org-museum-root-dir (file-directory-p org-museum-root-dir))
    (user-error "请先设置 org-museum-root-dir"))
  (let ((root (file-truename org-museum-root-dir)))
    (unless (equal root org-museum-knowledge--root)
      (when (timerp org-museum-knowledge--persist-timer)
        (cancel-timer org-museum-knowledge--persist-timer))
      (when (timerp org-museum-knowledge--auto-timer)
        (cancel-timer org-museum-knowledge--auto-timer))
      (let* ((state (org-museum-knowledge--read-json
                     (org-museum-knowledge--state-path)))
             (workers (alist-get 'maxWorkers (alist-get 'settings state))))
        (when (and (integerp workers) (<= 1 workers 4))
          (setq org-museum-knowledge-max-workers workers))
        (setq org-museum-knowledge--root root
              org-museum-knowledge--queue (alist-get 'queue state)))
      (setq
            org-museum-knowledge--analyses nil
            org-museum-knowledge--experiences nil
            org-museum-knowledge--relations nil)
      (let ((derived (org-museum-knowledge--read-json
                      (org-museum-knowledge--derived-path))))
        (setq org-museum-knowledge--analyses (alist-get 'analyses derived)
              org-museum-knowledge--experiences (alist-get 'experiences derived)
              org-museum-knowledge--relations (alist-get 'relations derived)))
      (dolist (job org-museum-knowledge--queue)
        (unless (assq 'error job)
          (nconc job (list (cons 'error nil))))
        (when (equal (alist-get 'status job) "running")
          (setf (alist-get 'status job) "dirty"))))))

(defun org-museum-knowledge--active-p (job)
  (memq job org-museum-knowledge--actives))

(defun org-museum-knowledge--log (job event &optional detail)
  (push `((at . ,(format-time-string "%FT%T%z"))
          (file . ,(alist-get 'file job)) (event . ,event)
          (detail . ,(or detail ""))) org-museum-knowledge--batch-log))

(defun org-museum-knowledge--batch-status ()
  (let ((jobs (or (alist-get 'jobs org-museum-knowledge--batch) nil))
        dirty running done failed)
    (dolist (job jobs)
      (pcase (alist-get 'status job)
        ("dirty" (setq dirty (1+ (or dirty 0))))
        ("running" (setq running (1+ (or running 0))))
        ("done" (setq done (1+ (or done 0))))
        ("failed" (setq failed (1+ (or failed 0))))))
    `((total . ,(length jobs))
      (reused . ,(or (alist-get 'reused org-museum-knowledge--batch) 0))
      (queued . ,(or dirty 0)) (running . ,(or running 0))
      (done . ,(or done 0)) (failed . ,(or failed 0)))))

(defun org-museum-knowledge--start-batch (files)
  "Create a batch for FILES, reusing current analyses when hashes match."
  (org-museum-knowledge--ensure)
  (let ((reused 0) jobs)
    (dolist (file (delete-dups (mapcar #'expand-file-name files)))
      (when (file-regular-p file)
        (let* ((hash (org-museum-knowledge--file-hash file))
               (analysis (org-museum-knowledge--analysis file))
               (job (org-museum-knowledge--job file)))
          (if (and analysis (equal hash (alist-get 'hash analysis)))
              (progn
                (setq reused (1+ reused))
                (when job (setf (alist-get 'status job) "done"
                                (alist-get 'hash job) hash))
                (unless job
                  (setq job (list (cons 'file file) (cons 'hash hash)
                                  (cons 'status "done") (cons 'attempts 0)
                                  (cons 'error nil)))
                  (push job org-museum-knowledge--queue)))
            (org-museum-knowledge--mark-dirty file hash)
            (setq job (org-museum-knowledge--job file))
            ;; An explicit batch is a fresh user request.  A queued job may
            ;; still carry exhausted attempts from an earlier run with the
            ;; same content hash; otherwise no worker can claim it.
            (unless (org-museum-knowledge--active-p job)
              (setf (alist-get 'status job) "dirty"
                    (alist-get 'attempts job) 0
                    (alist-get 'error job) nil)))
          (push job jobs))))
    (when (and org-museum-knowledge--active
               (not (org-museum-knowledge--active-p org-museum-knowledge--active)))
      (setq org-museum-knowledge--requested-file
            (alist-get 'file (car jobs))))
    (setq org-museum-knowledge--batch
          `((id . ,(secure-hash 'sha256 (format "%s:%s" (float-time) (random))))
            (createdAt . ,(format-time-string "%FT%T%z"))
            (jobs . ,(nreverse jobs)) (reused . ,reused))
          org-museum-knowledge--batch-log nil
          org-museum-knowledge--drain t)
    (org-museum-knowledge--persist-state)
    (org-museum-knowledge--work-next)
    org-museum-knowledge--batch))

(defun org-museum-knowledge--batch-public ()
  (when org-museum-knowledge--batch
    (let* ((status (org-museum-knowledge--batch-status))
           (ready (and (= (alist-get 'failed status) 0)
                       (= (alist-get 'done status) (alist-get 'total status)))))
      `((ok . t) (batchId . ,(alist-get 'id org-museum-knowledge--batch))
        (status . ,(if ready "ready" "running"))
        (progress . ,status)
        (log . ,(vconcat (reverse org-museum-knowledge--batch-log)))
        (analyses . ,(vconcat
                      (delq nil
                            (mapcar (lambda (job)
                                      (let ((item (org-museum-knowledge--analysis
                                                   (alist-get 'file job))))
                                        (when item
                                          `((file . ,(alist-get 'file job))
                                            (hash . ,(alist-get 'hash item))
                                            (summary . ,(alist-get 'summary item))))))
                                    (alist-get 'jobs org-museum-knowledge--batch)))))
        (conflicts . ,(vconcat (org-museum-knowledge--conflicts)))))))

(defun org-museum-knowledge--persist-state ()
  (setq org-museum-knowledge--persist-timer nil)
  (org-museum-knowledge--write-json
   (org-museum-knowledge--state-path)
   `((schemaVersion . 1)
     (settings . ((maxWorkers . ,org-museum-knowledge-max-workers)))
     (queue . ,(vconcat org-museum-knowledge--queue)))))

(defun org-museum-knowledge--set-max-workers (workers)
  "Set and persist the local analysis worker limit to WORKERS."
  (unless (and (integerp workers) (<= 1 workers 4))
    (user-error "并发 Worker 数量须为 1～4"))
  (org-museum-knowledge--ensure)
  (setq org-museum-knowledge-max-workers workers)
  (org-museum-knowledge--persist-state)
  (when org-museum-knowledge--batch
    (org-museum-knowledge--work-next))
  workers)

(defun org-museum-knowledge--persist-derived ()
  (org-museum-knowledge--write-json
   (org-museum-knowledge--derived-path)
   `((schemaVersion . 3)
     (analyses . ,(vconcat org-museum-knowledge--analyses))
     (experiences . ,(vconcat org-museum-knowledge--experiences))
     (relations . ,(vconcat org-museum-knowledge--relations)))))

(defun org-museum-knowledge--schedule-persist ()
  (when (timerp org-museum-knowledge--persist-timer)
    (cancel-timer org-museum-knowledge--persist-timer))
  (setq org-museum-knowledge--persist-timer
        (run-at-time 0.5 nil #'org-museum-knowledge--persist-state)))

(defun org-museum-knowledge--file-hash (file)
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun org-museum-knowledge--job (file)
  (cl-find file org-museum-knowledge--queue
           :key (lambda (job) (alist-get 'file job)) :test #'equal))

(defun org-museum-knowledge--analysis (file)
  (cl-find file org-museum-knowledge--analyses
           :key (lambda (item) (alist-get 'file item)) :test #'equal))

(defun org-museum-knowledge--mark-dirty (file &optional hash)
  "Record FILE content change without making an AI request."
  (org-museum-knowledge--ensure)
  (when (and (file-regular-p file) (string-suffix-p ".org" file))
    (let* ((path (expand-file-name file))
           (digest (or hash (org-museum-knowledge--file-hash path)))
           (analysis (org-museum-knowledge--analysis path))
           (job (org-museum-knowledge--job path)))
      (unless (equal digest (alist-get 'hash analysis))
        (cond
         (job
          (unless (equal digest (alist-get 'hash job))
            (setf (alist-get 'hash job) digest
                  (alist-get 'status job) "dirty"
                  (alist-get 'attempts job) 0
                  (alist-get 'error job) nil)))
         (t
          (push (list (cons 'file path) (cons 'hash digest)
                      (cons 'status "dirty") (cons 'attempts 0)
                      (cons 'error nil))
                org-museum-knowledge--queue)))
        (org-museum-knowledge--schedule-persist)
        (org-museum-knowledge--schedule-auto)))))

(defun org-museum-knowledge--on-save ()
  "Fast save hook: hash the saved buffer, then defer the state write."
  (when (and (bound-and-true-p org-museum-mode)
             (buffer-file-name)
             (org-museum--file-in-project-p (buffer-file-name)))
    (org-museum-knowledge--mark-dirty
     (buffer-file-name) (secure-hash 'sha256 (current-buffer)))))

(defun org-museum-knowledge--schedule-auto ()
  (when (timerp org-museum-knowledge--auto-timer)
    (cancel-timer org-museum-knowledge--auto-timer))
  (when (and (eq org-museum-knowledge-work-mode 'auto)
             (not org-museum-knowledge--paused))
    (setq org-museum-knowledge--auto-timer
          (run-with-idle-timer org-museum-knowledge-idle-seconds nil
                               #'org-museum-knowledge--work-next))))

(defun org-museum-knowledge--source-text (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-substring-no-properties
     (point-min) (min (point-max)
                      (+ (point-min) org-museum-knowledge-source-limit)))))

(defun org-museum-knowledge--local-backend (&optional stream)
  (unless (and (require 'gptel nil t)
               (require 'gptel-openai nil t))
    (user-error "gptel 不可用；分析任务仍保留在队列中"))
  (let ((name (format "Org Museum LM Studio %s@%s"
                      org-museum-knowledge-local-model
                      org-museum-knowledge-local-host)))
    (gptel-make-openai
     name :host org-museum-knowledge-local-host
     :protocol "http" :endpoint "/v1/chat/completions"
     :stream stream :key "lm-studio"
     :curl-args '("--noproxy" "*")
     :models (list (intern org-museum-knowledge-local-model)))))

(defun org-museum-knowledge--backend ()
  (if org-museum-knowledge--cloud-backend
      (or (ignore-errors (gptel-get-backend org-museum-knowledge--cloud-backend))
          (user-error "所选 gptel 后端不可用"))
    (org-museum-knowledge--local-backend)))

(defun org-museum-knowledge-select-backend (name model)
  "Explicitly select gptel backend NAME and MODEL, or local for LM Studio."
  (interactive
   (progn
     (unless (require 'gptel nil t) (user-error "gptel 不可用"))
     (let* ((names (cons "LM Studio（本机）"
                         (mapcar #'car gptel--known-backends)))
            (name (completing-read "分析后端：" names nil t)))
       (list name (unless (equal name "LM Studio（本机）")
                    (read-string "模型 ID：" (format "%s" gptel-model)))))))
  (if (member name '("LM Studio（本机）" "LM Studio (local)"))
      (setq org-museum-knowledge--cloud-backend nil
            org-museum-knowledge--cloud-model nil)
    (unless (ignore-errors (gptel-get-backend name))
      (user-error "找不到 gptel 后端：%s" name))
    (setq org-museum-knowledge--cloud-backend name
          org-museum-knowledge--cloud-model model))
  (message "Org Museum 分析后端：%s" name))

(defun org-museum-knowledge--model ()
  (or org-museum-knowledge--cloud-model org-museum-knowledge-local-model))

(defun org-museum-knowledge--send-request (job hash backend file &optional buffer)
  "Send one explicitly configured gptel request after preflight."
  (with-current-buffer (or buffer (alist-get job org-museum-knowledge--request-buffers nil nil #'eq))
    (let ((gptel-backend backend)
          (gptel-model (intern (org-museum-knowledge--model)))
          (gptel-use-context nil)
          (gptel-use-tools nil)
          (url-proxy-services
           (if org-museum-knowledge--cloud-backend url-proxy-services
             '(("no_proxy" . "127\\.0\\.0\\.1\\|localhost"))))
          (gptel-prompt-transform-functions nil))
      (gptel-request
       (concat "原文文件：" (file-name-nondirectory file)
               "\n原文 SHA-256：" hash "\n\n"
               (org-museum-knowledge--source-text file))
       :system
       (concat "请用自然、简洁的中文分析这篇 Org 笔记。SQL、代码、字段名和函数名保留原文；"
               "其余内容不要使用英文段落。只输出 Markdown 正文，使用‘核心要点’、"
               "‘方法与依据’、‘结论’、‘待核实’四个二级标题；各节用短段落或列表。"
               "每项判断都注明对应的原文标题或简短摘录，不得编造事实。"
               "如果没有待核实内容，写‘暂无’。不要包裹整个回答的代码块。")
       :stream nil
       :callback
       (lambda (response info)
         (unless (and (consp response)
                      (eq (car response) 'reasoning))
           (org-museum-knowledge--finish
            job hash response (plist-get info :status))))))))

(defun org-museum-knowledge--preflight-local (job hash backend file &optional buffer)
  "Check that the chosen LM Studio model is loaded without blocking Emacs."
  (let ((url-proxy-services '(("no_proxy" . "127\\.0\\.0\\.1\\|localhost"))))
    (url-retrieve
     (format "http://%s/api/v1/models" org-museum-knowledge-local-host)
     (lambda (status)
     (unwind-protect
         (when (org-museum-knowledge--active-p job)
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
                        (model (cl-find org-museum-knowledge-local-model
                                        (alist-get 'models data)
                                        :key (lambda (entry) (alist-get 'key entry))
                                        :test #'equal)))
                   (unless (and model (alist-get 'loaded_instances model))
                     (error "请先在 LM Studio 中加载 %s，再重试队列中的分析"
                            org-museum-knowledge-local-model)))
                 (org-museum-knowledge--send-request job hash backend file buffer))
             (error (org-museum-knowledge--fail job (error-message-string err)))))
       (kill-buffer (current-buffer))))
     nil t t)))

(defun org-museum-knowledge--work-next ()
  "Fill all available analysis workers from the shared queue."
  (setq org-museum-knowledge--auto-timer nil)
  (org-museum-knowledge--ensure)
  (dolist (job org-museum-knowledge--queue)
    (when (and (equal (alist-get 'status job) "running")
               (not (org-museum-knowledge--active-p job)))
      (setf (alist-get 'status job) "dirty")))
  (unless org-museum-knowledge--paused
    (let ((slots (if (and org-museum-knowledge--active
                          (not (org-museum-knowledge--active-p
                                org-museum-knowledge--active)))
                     0
                   (max 0 (- org-museum-knowledge-max-workers
                            (length org-museum-knowledge--actives)))))
          (eligible (lambda (entry)
                      (and (equal (alist-get 'status entry) "dirty")
                           (< (or (alist-get 'attempts entry) 0)
                              (1+ org-museum-knowledge-max-retries)))))
          jobs)
      (while (and (> slots 0)
                  (setq jobs
                        (append
                         (cl-remove-if-not eligible
                                           (alist-get 'jobs org-museum-knowledge--batch))
                         (when (or (null org-museum-knowledge--batch)
                                   (eq org-museum-knowledge-work-mode 'auto))
                           (cl-remove-if-not
                            (lambda (entry)
                              (and (funcall eligible entry)
                                   (not (memq entry
                                              (alist-get 'jobs org-museum-knowledge--batch)))))
                            (reverse org-museum-knowledge--queue))))))
        (when-let* ((requested (and org-museum-knowledge--requested-file
                                    (org-museum-knowledge--job
                                     org-museum-knowledge--requested-file))))
          (setq jobs (cons requested (delq requested jobs))))
        (let* ((job (car jobs))
               (file (alist-get 'file job))
               (hash (alist-get 'hash job))
               (buffer (generate-new-buffer " *org-museum-analysis*"))
               backend)
          (setq slots (1- slots))
          (when (equal file org-museum-knowledge--requested-file)
            (setq org-museum-knowledge--requested-file nil))
          (condition-case err
              (progn
                (unless (file-regular-p file) (error "找不到原笔记"))
                (setq backend (org-museum-knowledge--backend))
                (setf (alist-get 'status job) "running"
                      (alist-get 'startedAt job) (format-time-string "%FT%T%z"))
                (push job org-museum-knowledge--actives)
                (push (cons job buffer) org-museum-knowledge--request-buffers)
                (setq org-museum-knowledge--active (car org-museum-knowledge--actives)
                      org-museum-knowledge--request-buffer buffer)
                (org-museum-knowledge--log job "started")
                (org-museum-knowledge--persist-state)
                (if org-museum-knowledge--cloud-backend
                    (org-museum-knowledge--send-request job hash backend file buffer)
                  (org-museum-knowledge--preflight-local job hash backend file))
                (push (cons job (run-at-time org-museum-knowledge-timeout-seconds nil
                                             #'org-museum-knowledge--timeout job))
                      org-museum-knowledge--request-timers))
            (error
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (org-museum-knowledge--fail job (error-message-string err))))))))
  (org-museum-knowledge--persist-state))

(defun org-museum-knowledge--cleanup-job (job)
  (when-let ((timer (alist-get job org-museum-knowledge--request-timers nil nil #'eq)))
    (cancel-timer timer)
    (setq org-museum-knowledge--request-timers
          (assq-delete-all job org-museum-knowledge--request-timers)))
  (when-let ((buffer (alist-get job org-museum-knowledge--request-buffers nil nil #'eq)))
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (setq org-museum-knowledge--request-buffers
          (assq-delete-all job org-museum-knowledge--request-buffers)))
  (setq org-museum-knowledge--actives (delq job org-museum-knowledge--actives)
        org-museum-knowledge--active (car org-museum-knowledge--actives)
        org-museum-knowledge--request-buffer
        (cdr (assq org-museum-knowledge--active org-museum-knowledge--request-buffers))))

(defun org-museum-knowledge--timeout (job)
  (when (org-museum-knowledge--active-p job)
    (org-museum-knowledge--log job "timeout")
    (org-museum-knowledge--fail job "请求超时")))

(defun org-museum-knowledge--fail (job reason)
  (let ((attempts (1+ (or (alist-get 'attempts job) 0))))
    (setf (alist-get 'status job)
          (if (<= attempts org-museum-knowledge-max-retries)
              "dirty" "failed")
          (alist-get 'attempts job) attempts))
  (setf
        (alist-get 'error job) (or reason "AI 请求失败"))
  (org-museum-knowledge--log job (if (equal (alist-get 'status job) "dirty") "retry" "failed") reason)
  (org-museum-knowledge--cleanup-job job)
  (org-museum-knowledge--persist-state)
  (message "Org Museum 分析失败；任务已保留在队列中：%s"
           (alist-get 'error job))
  (run-at-time 0 nil #'org-museum-knowledge--work-next))

(defun org-museum-knowledge--finish (job hash response status)
  (when (org-museum-knowledge--active-p job)
    (let ((file (alist-get 'file job)))
      (if (not (stringp response))
          (org-museum-knowledge--fail job (format "%s" status))
        (if (not (equal hash (org-museum-knowledge--file-hash file)))
            (progn
              (setf (alist-get 'status job) "dirty"
                    (alist-get 'hash job) (org-museum-knowledge--file-hash file))
              (org-museum-knowledge--cleanup-job job)
              (org-museum-knowledge--persist-state))
          (let* ((old (org-museum-knowledge--analysis file))
                 (item `((file . ,file) (hash . ,hash)
                         (summary . ,response)
                         (source . ,(file-relative-name file org-museum-root-dir))
                         (generatedAt . ,(format-time-string "%FT%T%z"))
                         (method . "gptel")
                         (backend . ,(or org-museum-knowledge--cloud-backend
                                         "LM Studio"))
                         (model . ,(org-museum-knowledge--model))
                         (language . "zh-CN")
                         (verification . "ai-inference"))))
            (setq org-museum-knowledge--analyses
                  (cons item (delq old org-museum-knowledge--analyses)))
            (org-museum-knowledge--persist-derived)
            (setf (alist-get 'status job) "done"
                  (alist-get 'error job) nil)
            (org-museum-knowledge--log job "finished")
            (org-museum-knowledge--cleanup-job job)
            (org-museum-knowledge--persist-state)
            (message "Org Museum 已分析 %s" (file-name-nondirectory file)))))
      (run-at-time 0 nil #'org-museum-knowledge--work-next))))

(defun org-museum-knowledge--enqueue-file (file)
  (org-museum-knowledge--mark-dirty file)
  (when-let* ((job (org-museum-knowledge--job (expand-file-name file))))
    (when (and (equal (alist-get 'status job) "running")
               (not (org-museum-knowledge--active-p job)))
      (setf (alist-get 'status job) "dirty"))
    (when (or (equal (alist-get 'status job) "failed")
              (and (equal (alist-get 'status job) "done")
                   (not (equal (alist-get 'hash job)
                               (alist-get 'hash
                                          (org-museum-knowledge--analysis
                                           (expand-file-name file)))))))
      (setf (alist-get 'status job) "dirty"
            (alist-get 'attempts job) 0))
    (org-museum-knowledge--persist-state)))

;;;###autoload
(defun org-museum-analyze-current ()
  "Analyze the current Org note on explicit request."
  (interactive)
  (unless (and (buffer-file-name) (org-museum--file-in-project-p (buffer-file-name)))
    (user-error "请先打开一篇 Org Museum 笔记"))
  (org-museum-knowledge--start-batch (list (buffer-file-name))))

;;;###autoload
(defun org-museum-analyze-dirty ()
  "Start analysis of dirty notes; process one request at a time."
  (interactive)
  (org-museum-knowledge--ensure)
  (dolist (job org-museum-knowledge--queue)
    (when (equal (alist-get 'status job) "failed")
      (setf (alist-get 'status job) "dirty"
            (alist-get 'attempts job) 0)))
  (org-museum-knowledge--start-batch
   (mapcar (lambda (job) (alist-get 'file job))
           (cl-remove-if-not (lambda (job)
                              (member (alist-get 'status job) '("dirty" "failed")))
                             org-museum-knowledge--queue))))

;;;###autoload
(defun org-museum-analyze-project ()
  "Queue changed Org Museum notes, then start one analysis."
  (interactive)
  (org-museum-knowledge--ensure)
  (org-museum-knowledge--start-batch (org-museum--scan-files)))

(defun org-museum-ai-pause ()
  "Pause or resume optional background analysis."
  (interactive)
  (setq org-museum-knowledge--paused (not org-museum-knowledge--paused))
  (unless org-museum-knowledge--paused (org-museum-knowledge--schedule-auto))
  (message "Org Museum AI 已%s" (if org-museum-knowledge--paused "暂停" "继续")))

(defun org-museum-ai-set-mode (mode)
  "Select manual, assist, or auto analysis MODE."
  (interactive
   (list (cdr (assoc (completing-read "知识处理模式："
                                     '("手动" "辅助" "自动") nil t)
                     '(("手动" . manual) ("辅助" . assist) ("自动" . auto))))))
  (unless (memq mode '(manual assist auto))
    (user-error "无法识别知识处理模式：%s" mode))
  (setq org-museum-knowledge-work-mode mode)
  (org-museum-knowledge--schedule-auto)
  (message "Org Museum 知识处理模式：%s"
           (cdr (assq mode '((manual . "手动") (assist . "辅助")
                             (auto . "自动"))))))

(defun org-museum-ai-cancel ()
  "Cancel all active analyses and retain them as dirty."
  (interactive)
  (setq org-museum-knowledge--drain nil
        org-museum-knowledge--requested-file nil)
  (dolist (job (copy-sequence org-museum-knowledge--actives))
    (let ((buffer (alist-get job org-museum-knowledge--request-buffers nil nil #'eq)))
      (setf (alist-get 'status job) "dirty"
            (alist-get 'error job) "已取消")
      (when (and (buffer-live-p buffer) (fboundp 'gptel-abort))
        (gptel-abort buffer))
      (org-museum-knowledge--log job "cancelled")
      (org-museum-knowledge--cleanup-job job)))
  (org-museum-knowledge--persist-state))

(defun org-museum-ai-queue-clear ()
  "Clear queued jobs, leaving analyses and original notes untouched."
  (interactive)
  (org-museum-knowledge--ensure)
  (org-museum-ai-cancel)
  (setq org-museum-knowledge--queue nil)
  (org-museum-knowledge--persist-state))

(defun org-museum-knowledge--normalise (value)
  (downcase (or value "")))

(defun org-museum-knowledge--terms (value)
  "Extract portable Latin words and overlapping CJK pairs from VALUE."
  (let ((text (org-museum-knowledge--normalise value)) terms)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "[a-z0-9_-]+" nil t)
        (push (match-string 0) terms))
      (goto-char (point-min))
      (while (re-search-forward "[一-鿿][一-鿿]+" nil t)
        (let ((word (match-string 0)))
          (dotimes (i (1- (length word)))
            (push (substring word i (+ i 2)) terms)))))
    (delete-dups terms)))

(defun org-museum-knowledge--score (query text)
  (let ((haystack (org-museum-knowledge--normalise text))
        (score 0))
    (dolist (term (org-museum-knowledge--terms query))
      (when (string-match-p (regexp-quote term) haystack)
        (cl-incf score)))
    score))

(defun org-museum-knowledge--page-for-file (file)
  (when org-museum--index
    (org-museum--find-page-by-path file (org-museum-index-pages org-museum--index))))

(defun org-museum-knowledge--experience-page-id (item)
  (alist-get 'pageId item))

(defun org-museum-knowledge--experience-current-p (item)
  (let ((file (alist-get 'file item)))
    (and (stringp file) (file-regular-p file)
         (equal (alist-get 'sourceHash item)
                (org-museum-knowledge--file-hash file)))))

(defun org-museum-knowledge--failure-p (item)
  (equal (alist-get 'type item) "failure-pattern"))

(defun org-museum-knowledge--has-failed-attempt-p (item)
  (or (org-museum-knowledge--failure-p item)
      (let ((wrong (alist-get 'wrongAttempt item)))
        (and (stringp wrong) (not (string-empty-p (string-trim wrong)))))))

(defun org-museum-knowledge--recorded-result-p (excerpt)
  "Whether EXCERPT contains an Org results header and a nonempty result line."
  (let ((case-fold-search t))
    (and (stringp excerpt)
         (string-match-p (rx line-start "#+RESULTS:" (* nonl)
                             "\n" (* (any " \t")) (not (any " \t\n")))
                         excerpt))))

(defun org-museum-knowledge--experience-score (query item &optional current-id)
  "Score ITEM for QUERY, giving verified failure patterns priority."
  (let ((overlap (org-museum-knowledge--score
                  query (mapconcat (lambda (key) (or (alist-get key item) ""))
                                   '(problem cause wrongAttempt result scope) " "))))
    (if (= overlap 0) 0
      (+ (* 3 overlap)
         (cond ((org-museum-knowledge--failure-p item) 6)
               ((org-museum-knowledge--has-failed-attempt-p item) 3)
               (t 0))
         (if (equal (alist-get 'verification item) "recorded-result") 3 0)
         (if (and current-id (equal current-id (alist-get 'pageId item))) 4 0)))))

(defun org-museum-knowledge--evidence-at-point ()
  "Capture a source excerpt with a stable line and hash for review.
An active region can include an Org Babel result.  The excerpt is kept in
the private derived layer, never copied into public HTML."
  (let* ((start (if (use-region-p) (region-beginning) (line-beginning-position)))
         (end (if (use-region-p) (region-end) (line-end-position)))
         (excerpt (string-trim (buffer-substring-no-properties start end)))
         (line (line-number-at-pos start))
         (heading (save-excursion
                    (goto-char start)
                    (when (ignore-errors (org-back-to-heading t))
                      (org-get-heading t t t t)))))
    `((kind . ,(if (org-museum-knowledge--recorded-result-p excerpt)
                     "org-result" "org-source"))
      (file . ,(expand-file-name (buffer-file-name)))
      (line . ,line)
      (heading . ,(or heading ""))
      (excerpt . ,excerpt)
      (excerptHash . ,(secure-hash 'sha256 excerpt))
      (capturedAt . ,(format-time-string "%FT%T%z")))))

(defun org-museum-knowledge--verification-label (item)
  (pcase (alist-get 'verification item)
    ("recorded-result" "原笔记含执行结果（未重新执行）")
    ("user-confirmed" "用户确认")
    (_ "未验证")))

(defun org-museum-knowledge--failure-reminder (buffer)
  "Show one concise reminder for BUFFER when a similar verified pitfall exists."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (bound-and-true-p org-museum-mode)
                 (not org-museum-knowledge--reminded)
                 (buffer-file-name)
                 (org-museum--file-in-project-p (buffer-file-name)))
        (org-museum-knowledge--ensure)
        (let* ((query (concat (or (ignore-errors (org-get-title)) "") " "
                              (buffer-substring-no-properties
                               (point-min) (min (point-max) (+ (point-min) 1200)))))
               (best (car (sort
                           (cl-remove-if-not
                            (lambda (pair)
                              (>= (car pair) org-museum-knowledge-reminder-min-score))
                            (mapcar
                             (lambda (item)
                               (cons (org-museum-knowledge--score
                                      query (concat (or (alist-get 'problem item) "") " "
                                                    (or (alist-get 'cause item) "") " "
                                                    (or (alist-get 'wrongAttempt item) "")))
                                     item))
                             (cl-remove-if-not
                              (lambda (item)
                                (and (org-museum-knowledge--has-failed-attempt-p item)
                                     (org-museum-knowledge--experience-current-p item)
                                     (not (equal (alist-get 'file item)
                                                 (expand-file-name (buffer-file-name))))))
                              org-museum-knowledge--experiences)))
                           (lambda (a b) (> (car a) (car b)))))))
          (setq org-museum-knowledge--reminded t)
          (when best
            (message "Org Museum 历史踩坑：%s；避免：%s。用 M-x org-museum-recall 查看来源"
                     (alist-get 'problem (cdr best))
                     (alist-get 'wrongAttempt (cdr best)))))))))

(defun org-museum-knowledge--schedule-failure-reminder ()
  "Check the current note once after opening, without a model request."
  (when (and (buffer-file-name) (not org-museum-knowledge--reminded))
    (run-with-idle-timer org-museum-knowledge-reminder-idle-seconds nil
                         #'org-museum-knowledge--failure-reminder
                         (current-buffer))))

(defconst org-museum-knowledge--relation-types
  '(("supports" . "支持") ("contradicts" . "矛盾")
    ("depends-on" . "依赖") ("applies-to" . "应用于")
    ("influences" . "启发影响") ("part-of" . "属于")
    ("related" . "相关"))
  "Canonical relation types in the private knowledge layer.")

(defun org-museum-knowledge--relation-type-from-label (label)
  "Map an author's Org annotation LABEL to a conservative relation type."
  (let ((case-fold-search t))
    (cond ((string-match-p "冲突\\|矛盾\\|反驳\\|contradict" label) "contradicts")
          ((string-match-p "前置\\|依赖\\|depend\\|prerequisite" label) "depends-on")
          ((string-match-p "支持\\|佐证\\|证实\\|support" label) "supports")
          ((string-match-p "适用\\|应用\\|实例\\|appl" label) "applies-to")
          ((string-match-p "启发\\|影响\\|influenc" label) "influences")
          ((string-match-p "属于\\|组成\\|part.of" label) "part-of")
          (t "related"))))

(defun org-museum-knowledge--relation-label (relation)
  (or (alist-get 'label relation)
      (cdr (assoc (alist-get 'type relation)
                  org-museum-knowledge--relation-types))
      "相关"))

(defun org-museum-knowledge--relation-current-p (relation)
  "A confirmed relation is active only while both source versions match."
  (let ((source (alist-get 'sourceFile relation))
        (target (alist-get 'targetFile relation)))
    (and (stringp source) (file-regular-p source)
         (stringp target) (file-regular-p target)
         (equal (alist-get 'sourceHash relation)
                (org-museum-knowledge--file-hash source))
         (equal (alist-get 'targetHash relation)
                (org-museum-knowledge--file-hash target)))))

(defun org-museum-knowledge--annotation-relations ()
  "Read author-labeled Org links from the existing index without changing it."
  (let ((pages (and org-museum--index
                    (org-museum-index-pages org-museum--index)))
        result)
    (when pages
      (maphash
       (lambda (_id page)
         (dolist (annotation (org-museum-page-relation-types page))
           (when-let* ((target (gethash (car annotation) pages)))
             (let* ((label (cdr annotation))
                    (type (org-museum-knowledge--relation-type-from-label label)))
               (push `((sourcePageId . ,(org-museum-page-id page))
                       (targetPageId . ,(org-museum-page-id target))
                       (sourceFile . ,(org-museum-page-path page))
                       (targetFile . ,(org-museum-page-path target))
                       (type . ,type) (label . ,label)
                       (confidence . ,(if (equal type "related") 0.65 0.95))
                       (origin . "org-annotation"))
                     result)))))
       pages))
    (nreverse result)))

(defun org-museum-knowledge--effective-relations ()
  "Return current confirmed relations and live author annotations."
  (append (cl-remove-if-not #'org-museum-knowledge--relation-current-p
                            org-museum-knowledge--relations)
          (org-museum-knowledge--annotation-relations)))

(defun org-museum-knowledge--relation-between (source-id target-id relations)
  "Find the strongest semantic relation between two page IDs."
  (car (sort
        (cl-remove-if-not
         (lambda (relation)
           (or (and (equal source-id (alist-get 'sourcePageId relation))
                    (equal target-id (alist-get 'targetPageId relation)))
               (and (equal target-id (alist-get 'sourcePageId relation))
                    (equal source-id (alist-get 'targetPageId relation)))))
         (copy-sequence relations))
        (lambda (a b)
          (> (or (alist-get 'confidence a) 0)
             (or (alist-get 'confidence b) 0))))))

(defun org-museum-knowledge--relation-boost (relation)
  "Return a bounded recall boost for a sourced relation."
  (if (null relation) 0
    (let ((base (pcase (alist-get 'type relation)
                  ("contradicts" 6) ("supports" 5)
                  ("depends-on" 5) ("applies-to" 4)
                  ("influences" 4) ("part-of" 3)
                  (_ 2))))
      (round (* base (or (alist-get 'confidence relation) 0))))))

(defun org-museum-knowledge--conflicts (&optional relations)
  "Return reviewable conflicts among sourced relations and confirmed fixes.
These are possible contradictions, never automatic truth judgments."
  (let ((items (or relations (org-museum-knowledge--effective-relations)))
        conflicts)
    (cl-loop for rest on items
             for first = (car rest)
             do (dolist (second (cdr rest))
                  (let ((same (and (equal (alist-get 'sourcePageId first)
                                          (alist-get 'sourcePageId second))
                                   (equal (alist-get 'targetPageId first)
                                          (alist-get 'targetPageId second))))
                        (reverse (and (equal (alist-get 'sourcePageId first)
                                             (alist-get 'targetPageId second))
                                      (equal (alist-get 'targetPageId first)
                                             (alist-get 'sourcePageId second)))))
                    (cond
                     ((and same
                           (member (alist-get 'type first)
                                   '("supports" "contradicts"))
                           (member (alist-get 'type second)
                                   '("supports" "contradicts"))
                           (not (equal (alist-get 'type first)
                                       (alist-get 'type second))))
                      (push (list 'opposed-relations first second) conflicts))
                     ((and reverse
                           (equal (alist-get 'type first) "depends-on")
                           (equal (alist-get 'type second) "depends-on"))
                      (push (list 'circular-dependency first second) conflicts))))))
    (cl-loop for rest on org-museum-knowledge--experiences
             for first = (car rest)
             when (and (eq (alist-get 'published first) t)
                       (org-museum-knowledge--experience-current-p first)
                       (stringp (alist-get 'problem first))
                       (stringp (alist-get 'result first)))
             do (dolist (second (cdr rest))
                  (when (and (eq (alist-get 'published second) t)
                             (org-museum-knowledge--experience-current-p second)
                             (equal (org-museum-knowledge--normalise
                                     (string-trim (alist-get 'problem first)))
                                    (org-museum-knowledge--normalise
                                     (string-trim (or (alist-get 'problem second) ""))))
                             (not (equal (org-museum-knowledge--normalise
                                          (string-trim (alist-get 'result first)))
                                         (org-museum-knowledge--normalise
                                          (string-trim (or (alist-get 'result second) "")))))
                             (equal (org-museum-knowledge--normalise
                                     (or (alist-get 'scope first) ""))
                                    (org-museum-knowledge--normalise
                                     (or (alist-get 'scope second) ""))))
                    (push (list 'divergent-fixes first second) conflicts))))
    (nreverse conflicts)))

(defun org-museum-knowledge--relation-summary (relation)
  (when relation
    (format "关系：%s → %s · %s · 置信度 %.2f · 来源：%s%s\n"
            (alist-get 'sourcePageId relation)
            (alist-get 'targetPageId relation)
            (org-museum-knowledge--relation-label relation)
            (or (alist-get 'confidence relation) 0)
            (if (equal (alist-get 'origin relation) "org-annotation")
                (format "Org 标注 %s" (alist-get 'sourceFile relation))
              (format "用户确认 %s" (alist-get 'sourceFile relation)))
            (if-let* ((line (alist-get 'line (alist-get 'evidence relation))))
                (format " 第 %d 行" line) ""))))

(defun org-museum-knowledge--pair-conflicting-p (source-id target-id relations)
  "Whether active relations between SOURCE-ID and TARGET-ID disagree."
  (let ((types (mapcar
                (lambda (relation) (alist-get 'type relation))
                (cl-remove-if-not
                 (lambda (relation)
                   (and (equal source-id (alist-get 'sourcePageId relation))
                        (equal target-id (alist-get 'targetPageId relation))))
                 relations))))
    (and (member "supports" types) (member "contradicts" types))))

(defun org-museum-knowledge--choose-target-page ()
  (unless org-museum--index (org-museum-index-build))
  (let ((current (and (buffer-file-name)
                      (org-museum-knowledge--page-for-file (buffer-file-name))))
        choices)
    (maphash
     (lambda (id page)
       (unless (and current (equal id (org-museum-page-id current)))
         (push (cons (format "%s [%s]" (org-museum-page-title page) id) id)
               choices)))
     (org-museum-index-pages org-museum--index))
    (cdr (assoc (completing-read "关联到笔记：" choices nil t)
                choices))))

;;;###autoload
(defun org-museum-relate-current (target-id type confidence evidence)
  "Confirm a sourced semantic relation from this note to TARGET-ID.
The relation is private derived knowledge.  Original Org notes are untouched."
  (interactive
   (let ((evidence (org-museum-knowledge--evidence-at-point)))
     (list (org-museum-knowledge--choose-target-page)
           (car (rassoc (completing-read
                         "关系类型：" (mapcar #'cdr org-museum-knowledge--relation-types)
                         nil t)
                        org-museum-knowledge--relation-types))
           (read-number "置信度 (0–1)：" 0.8)
           evidence)))
  (unless (and (buffer-file-name)
               (org-museum--file-in-project-p (buffer-file-name)))
    (user-error "请先打开一篇 Org Museum 原笔记"))
  (when (buffer-modified-p)
    (user-error "记录关系前请先保存原笔记"))
  (unless (and (assoc type org-museum-knowledge--relation-types)
               (numberp confidence) (<= 0 confidence) (<= confidence 1))
    (user-error "请选择有效的关系类型和 0–1 之间的置信度"))
  (org-museum-knowledge--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let* ((source (org-museum-knowledge--page-for-file (buffer-file-name)))
         (target (gethash target-id (org-museum-index-pages org-museum--index)))
         (source-file (expand-file-name (buffer-file-name)))
         (target-file (and target (org-museum-page-path target)))
         (source-hash (org-museum-knowledge--file-hash source-file))
         (target-hash (and target-file
                           (org-museum-knowledge--file-hash target-file)))
         (item `((id . ,(secure-hash 'sha256
                                  (format "%s|%s|%s|%s|%s"
                                          source-file target-file type
                                          source-hash target-hash)))
                 (sourcePageId . ,(and source (org-museum-page-id source)))
                 (targetPageId . ,target-id)
                 (sourceFile . ,source-file) (targetFile . ,target-file)
                 (sourceHash . ,source-hash) (targetHash . ,target-hash)
                 (type . ,type)
                 (label . ,(cdr (assoc type org-museum-knowledge--relation-types)))
                 (confidence . ,confidence)
                 (origin . "user-confirmed")
                 (evidence . ,evidence)
                 (createdAt . ,(format-time-string "%FT%T%z")))))
    (unless (and source target (not (equal (org-museum-page-id source) target-id)))
      (user-error "请选择另一篇已索引笔记"))
    (unless (and (equal source-file (alist-get 'file evidence))
                 (stringp (alist-get 'excerpt evidence))
                 (not (string-empty-p (alist-get 'excerpt evidence)))
                 (equal (secure-hash 'sha256 (alist-get 'excerpt evidence))
                        (alist-get 'excerptHash evidence))
                 (with-temp-buffer
                   (insert-file-contents source-file)
                   (search-forward (alist-get 'excerpt evidence) nil t)))
      (user-error "请在已保存的 Org 笔记中选择原文作为依据"))
    (let ((opposed (cl-some
                    (lambda (conflict)
                      (and (eq (car conflict) 'opposed-relations)
                           (or (eq item (cadr conflict))
                               (eq item (caddr conflict)))))
                    (org-museum-knowledge--conflicts
                      (cons item (org-museum-knowledge--effective-relations))))))
      (with-current-buffer (get-buffer-create "*Org Museum 关系预览*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format
                 "* 语义关系候选\n\n%s → %s\n类型：%s\n置信度：%.2f\n来源：%s，第 %d 行\n来源版本：%s\n目标版本：%s\n\n依据摘录：\n#+begin_example\n%s\n#+end_example\n\n确认后仅保存于私有派生层；不改写 Org 原文。\n"
                 (org-museum-page-title source) (org-museum-page-title target)
                 (org-museum-knowledge--relation-label item) confidence
                 source-file (alist-get 'line evidence) source-hash target-hash
                 (alist-get 'excerpt evidence)))
        (when opposed
          (insert "\n待复核：现有关系对同一对笔记给出了相反判断。\n"))
        (org-mode)
        (view-mode 1))
        (display-buffer (current-buffer))))
    (when (yes-or-no-p "确认这条私有语义关系？")
      (unless (and (equal source-hash (org-museum-knowledge--file-hash source-file))
                   (equal target-hash (org-museum-knowledge--file-hash target-file)))
        (user-error "审核期间原笔记发生变化，请重新建立关系"))
      (unless (cl-find (alist-get 'id item) org-museum-knowledge--relations
                       :key (lambda (entry) (alist-get 'id entry)) :test #'equal)
        (push item org-museum-knowledge--relations)
        (org-museum-knowledge--persist-derived))
      (message "语义关系已确认，后续召回会使用它"))))

;;;###autoload
(defun org-museum-relation-remove (id)
  "Remove one confirmed derived relation by ID after review.
Org-authored annotations remain in their source note and are not changed."
  (interactive
   (progn
     (org-museum-knowledge--ensure)
     (unless org-museum-knowledge--relations
       (user-error "没有可移除的已确认关系"))
     (let ((choices
            (mapcar (lambda (item)
                      (cons (format "%s → %s · %s [%s]"
                                    (alist-get 'sourcePageId item)
                                    (alist-get 'targetPageId item)
                                    (org-museum-knowledge--relation-label item)
                                    (substring (alist-get 'id item) 0 8))
                            (alist-get 'id item)))
                    org-museum-knowledge--relations)))
       (list (cdr (assoc (completing-read "撤销关系：" choices nil t)
                         choices))))))
  (org-museum-knowledge--ensure)
  (let ((item (cl-find id org-museum-knowledge--relations
                       :key (lambda (entry) (alist-get 'id entry)) :test #'equal)))
    (unless item (user-error "这条关系已不存在"))
    (when (yes-or-no-p
           (format "撤销 %s → %s 的私有关系？"
                   (alist-get 'sourcePageId item) (alist-get 'targetPageId item)))
      (setq org-museum-knowledge--relations
            (delq item org-museum-knowledge--relations))
      (org-museum-knowledge--persist-derived)
      (message "语义关系已移除"))))

;;;###autoload
(defun org-museum-relations ()
  "Review sourced semantic relations, stale records, and possible conflicts."
  (interactive)
  (org-museum-knowledge--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let* ((relations (org-museum-knowledge--effective-relations))
         (conflicts (org-museum-knowledge--conflicts relations))
         (stale (cl-remove-if #'org-museum-knowledge--relation-current-p
                              org-museum-knowledge--relations)))
    (with-current-buffer (get-buffer-create "*Org Museum 笔记关系*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+TITLE: 语义关系\n\n有效关系：%d  待复核冲突：%d  来源变更：%d\n\n"
                        (length relations) (length conflicts) (length stale)))
        (dolist (conflict conflicts)
          (pcase-let ((`(,kind ,first ,second) conflict))
            (insert (format "* 待复核：%s\n%s\n%s\n\n"
                            kind
                            (if (eq kind 'divergent-fixes)
                                (format "%s → %s (%s)"
                                        (alist-get 'problem first)
                                        (alist-get 'result first)
                                        (alist-get 'file first))
                              (org-museum-knowledge--relation-summary first))
                            (if (eq kind 'divergent-fixes)
                                (format "%s → %s (%s)"
                                        (alist-get 'problem second)
                                        (alist-get 'result second)
                                        (alist-get 'file second))
                              (org-museum-knowledge--relation-summary second))))))
        (dolist (relation relations)
          (insert (format "* %s\n%s来源笔记：[[file:%s%s][打开]]\n\n"
                          (org-museum-knowledge--relation-label relation)
                          (org-museum-knowledge--relation-summary relation)
                          (alist-get 'sourceFile relation)
                          (if-let* ((line (alist-get 'line
                                                       (alist-get 'evidence relation))))
                              (format "::%d" line) ""))))
        (dolist (relation stale)
          (insert (format "* 来源已变更：%s → %s\n已暂停用于召回；请重新核对。\n\n"
                          (alist-get 'sourcePageId relation)
                          (alist-get 'targetPageId relation))))
        (org-mode)
        (goto-char (point-min))
        (view-mode 1))
      (display-buffer (current-buffer)))))

(defun org-museum-recall (query)
  "Find relevant notes and confirmed experience for QUERY."
  (interactive
   (list (read-string "要查找的知识或问题："
                      (or (thing-at-point 'sentence t) ""))))
  (org-museum-knowledge--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let* ((current (and (buffer-file-name)
                       (org-museum-knowledge--page-for-file (buffer-file-name))))
         (relations (org-museum-knowledge--effective-relations))
         matches derived-text)
    (dolist (item org-museum-knowledge--experiences)
      (let* ((relation (and current
                            (org-museum-knowledge--relation-between
                             (org-museum-page-id current)
                             (alist-get 'pageId item) relations)))
             (score (+ (org-museum-knowledge--experience-score
                        query item (and current (org-museum-page-id current)))
                       (org-museum-knowledge--relation-boost relation))))
        (when (and (> score 0)
                   (org-museum-knowledge--experience-current-p item))
          (push (list score 'experience item relation) matches))))
    (maphash
     (lambda (_id page)
       (let* ((file (org-museum-page-path page))
              (analysis (org-museum-knowledge--analysis file))
              (relation (and current
                             (org-museum-knowledge--relation-between
                              (org-museum-page-id current)
                              (org-museum-page-id page) relations)))
              (score (+ (org-museum-knowledge--score
                         query (concat (org-museum-page-title page) " "
                                       (or (org-museum-page-description page) "") " "
                                       (or (alist-get 'summary analysis) "")))
                        (org-museum-knowledge--relation-boost relation)
                        (if (and current
                                 (or (member (org-museum-page-id page)
                                             (org-museum-page-links-to current))
                                     (member (org-museum-page-id page)
                                             (org-museum-page-linked-from current))))
                            3 0))))
         (when (> score 0) (push (list score 'page page relation) matches))))
     (org-museum-index-pages org-museum--index))
    (setq matches (seq-take (sort matches (lambda (a b) (> (car a) (car b)))) 12))
    (setq derived-text
          (when (fboundp 'org-museum-derived--recall-text)
            (org-museum-derived--recall-text
             query (and current (org-museum-page-id current)))))
    (with-current-buffer (get-buffer-create "*Org Museum 知识上下文*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "#+TITLE: 当前知识上下文\n\n")
        (if (and (null matches) (string-empty-p (or derived-text "")))
            (insert "没有找到相关的已索引笔记或已确认经验。\n")
          (dolist (match matches)
            (pcase-let ((`(,score ,kind ,item ,relation) match))
              (pcase kind
                ('experience
                 (insert (format "* %s · 相关度 %d\n问题：%s\n解决方法：%s\n"
                                 (if (org-museum-knowledge--failure-p item)
                                     "历史失败模式" "历史经验")
                                 score (alist-get 'problem item)
                                 (alist-get 'result item)))
                 (when (org-museum-knowledge--failure-p item)
                   (insert (format "原因：%s\n适用范围：%s\n"
                                   (alist-get 'cause item) (alist-get 'scope item))))
                 (when-let* ((wrong (alist-get 'wrongAttempt item)))
                   (unless (string-empty-p wrong)
                     (insert (format "失败尝试：%s\n" wrong))))
                 (when relation
                   (insert (org-museum-knowledge--relation-summary relation))
                   (when (org-museum-knowledge--pair-conflicting-p
                          (org-museum-page-id current) (alist-get 'pageId item)
                          relations)
                     (insert "待复核：同一对笔记有支持和矛盾关系。\n")))
                 (let ((evidence (alist-get 'evidence item)))
                   (insert (format "验证：%s\n证据：[[file:%s%s][打开原笔记%s]]\n来源版本：%s\n"
                                   (org-museum-knowledge--verification-label item)
                                   (alist-get 'file item)
                                   (if (alist-get 'line evidence)
                                       (format "::%d" (alist-get 'line evidence)) "")
                                   (if (alist-get 'line evidence)
                                       (format "（第 %d 行）" (alist-get 'line evidence)) "")
                                   (or (alist-get 'sourceHash item) "未知")))
                   (when-let* ((excerpt (alist-get 'excerpt evidence)))
                     (insert (format "依据摘录：%s\n"
                                     (truncate-string-to-width
                                      (replace-regexp-in-string "[\n\r]+" " " excerpt)
                                      300 nil nil "…"))))
                   (insert "\n")))
                ('page
                 (insert (format "* 相关笔记 · %s · 相关度 %d\n[[file:%s][打开原笔记]]\n"
                                 (org-museum-page-title item) score
                                 (org-museum-page-path item)))
                 (when relation
                   (insert (org-museum-knowledge--relation-summary relation))
                   (when (org-museum-knowledge--pair-conflicting-p
                          (org-museum-page-id current) (org-museum-page-id item)
                          relations)
                     (insert "待复核：同一对笔记有支持和矛盾关系。\n")))
                 (insert "\n"))))))
        (when derived-text (insert derived-text))
        (org-mode)
        (goto-char (point-min))
        (view-mode 1))
      (display-buffer (current-buffer)))))

(defun org-museum-knowledge--page-html (page &optional out-file)
  "Return approved experience HTML relevant to PAGE."
  (when page
    (org-museum-knowledge--ensure)
    (let* ((public (cl-remove-if-not
                    (lambda (item) (eq (alist-get 'published item) t))
                    org-museum-knowledge--experiences))
           (own (cl-remove-if-not
                 (lambda (item)
                   (and (equal (alist-get 'pageId item) (org-museum-page-id page))
                        (org-museum-knowledge--experience-current-p item)))
                 public))
           (related
            (when out-file
              (seq-take
               (cl-remove-if-not
                (lambda (candidate)
                  (org-museum-knowledge--experience-current-p (cdr candidate)))
                (seq-take
                 (sort
                  (delq nil
                        (mapcar
                       (lambda (item)
                         (let* ((source-id (alist-get 'pageId item))
                                (score (+ (org-museum-knowledge--score
                                           (concat (org-museum-page-title page) " "
                                                   (or (org-museum-page-description page) ""))
                                           (concat (alist-get 'problem item) " "
                                                   (alist-get 'result item)))
                                          (if (or (member source-id (org-museum-page-links-to page))
                                                  (member source-id (org-museum-page-linked-from page)))
                                              3 0))))
                           (when (and (not (equal source-id (org-museum-page-id page)))
                                      (> score 1)
                                      (gethash source-id (org-museum-index-pages org-museum--index)))
                             (cons score item))))
                         public))
                  (lambda (a b) (> (car a) (car b))))
                 12))
               3)))
           (items (append (reverse own) (mapcar #'cdr related))))
      (when items
        (concat
         "<section class=\"org-museum-experience\" aria-labelledby=\"org-museum-experience-title\">"
         "<h2 id=\"org-museum-experience-title\">已确认经验</h2>"
         (mapconcat
          (lambda (item)
            (let* ((source-id (alist-get 'pageId item))
                   (own-item (equal source-id (org-museum-page-id page))))
              (concat
               "<article class=\"org-museum-experience-item\">"
               (if (org-museum-knowledge--failure-p item)
                   "<strong>失败模式</strong>" "")
               "<div class=\"org-museum-experience-title\" data-ai-markdown>"
               (org-museum--html-escape (alist-get 'problem item)) "</div>"
               (if (org-museum-knowledge--failure-p item)
                   (concat "<strong>原因：</strong><div data-ai-markdown>"
                           (org-museum--html-escape (or (alist-get 'cause item) ""))
                           "</div>") "")
               "<div data-ai-markdown>" (org-museum--html-escape (alist-get 'result item)) "</div>"
               (if-let* ((wrong (alist-get 'wrongAttempt item)))
                   (if (string-empty-p wrong) ""
                     (concat "<strong>曾经失败：</strong><div data-ai-markdown>"
                             (org-museum--html-escape wrong) "</div>")) "")
               (if (org-museum-knowledge--failure-p item)
                   (concat "<strong>适用范围：</strong><div data-ai-markdown>"
                           (org-museum--html-escape (or (alist-get 'scope item) ""))
                           "</div>") "")
               "<small>" (org-museum--html-escape
                           (org-museum-knowledge--verification-label item))
               " · 来源："
               (if own-item "本页 Org 原文"
                 (format "<a href=\"%s\">相关原笔记</a>"
                         (org-museum--html-escape
                          (org-museum--page-href source-id out-file) t)))
               (if-let* ((line (alist-get 'line (alist-get 'evidence item))))
                   (format " · 第 %d 行" line) "")
               "</small></article>")))
          items "")
         "</section>")))))

;;;###autoload
(defun org-museum-record-failure (evidence problem cause wrong-attempt fix scope)
  "Review and record one failure pattern from the current saved Org note.
Select a source region containing an Org #+RESULTS block when available.
Recorded results are evidence of the note's content, not a new execution."
  (interactive
   (let ((evidence (org-museum-knowledge--evidence-at-point)))
     (list evidence
           (read-string "遇到的问题：")
           (read-string "原因：")
           (read-string "失败尝试：")
           (read-string "实际修复：")
           (read-string "适用范围："))))
  (unless (and (buffer-file-name)
               (org-museum--file-in-project-p (buffer-file-name)))
    (user-error "记录失败经验前请先打开一篇 Org Museum 笔记"))
  (when (buffer-modified-p)
    (user-error "记录依据前请先保存 Org 原笔记"))
  (dolist (field (list problem cause wrong-attempt fix scope))
    (when (string-empty-p (string-trim field))
      (user-error "请填写问题、原因、失败尝试、修复方法和适用范围")))
  (org-museum-knowledge--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let* ((file (expand-file-name (buffer-file-name)))
         (page (org-museum-knowledge--page-for-file file))
         (hash (org-museum-knowledge--file-hash file))
         (verification (if (equal (alist-get 'kind evidence) "org-result")
                           "recorded-result" "user-confirmed"))
         (item `((id . ,(secure-hash 'sha256
                                     (concat file hash problem cause wrong-attempt fix scope)))
                 (type . "failure-pattern")
                 (file . ,file)
                 (pageId . ,(and page (org-museum-page-id page)))
                 (sourceHash . ,hash)
                 (problem . ,(string-trim problem))
                 (cause . ,(string-trim cause))
                 (wrongAttempt . ,(string-trim wrong-attempt))
                 (result . ,(string-trim fix))
                 (scope . ,(string-trim scope))
                 (verification . ,verification)
                 (evidence . ,evidence)
                 (createdAt . ,(format-time-string "%FT%T%z"))
                 (published . t))))
    (unless page (user-error "原笔记尚未索引"))
    (unless (and (equal file (alist-get 'file evidence))
                 (not (string-empty-p (alist-get 'excerpt evidence)))
                 (equal (secure-hash 'sha256 (alist-get 'excerpt evidence))
                        (alist-get 'excerptHash evidence))
                 (with-temp-buffer
                   (insert-file-contents file)
                   (search-forward (alist-get 'excerpt evidence) nil t))
                 (or (not (equal verification "recorded-result"))
                     (org-museum-knowledge--recorded-result-p
                      (alist-get 'excerpt evidence))))
      (user-error "依据与当前原笔记不符"))
    (with-current-buffer (get-buffer-create "*Org Museum 失败经验预览*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format
                 "* Failure Pattern 候选\n\nProblem：%s\nCause：%s\nWrong Attempt：%s\nFix：%s\nVerification：%s\nScope：%s\n\nProvenance：%s，第 %d 行\nSource SHA-256：%s\n\nEvidence 摘录：\n#+begin_example\n%s\n#+end_example\n\n确认后进入派生层并公开；原 Org 正文不会被修改。\n"
                 problem cause wrong-attempt fix
                 (org-museum-knowledge--verification-label item)
                 scope file (alist-get 'line evidence) hash
                 (alist-get 'excerpt evidence)))
        (org-mode)
        (view-mode 1))
      (display-buffer (current-buffer)))
    (when (yes-or-no-p "沉淀并公开这条 Failure Pattern？")
      (unless (equal hash (org-museum-knowledge--file-hash file))
        (user-error "审核期间原笔记发生变化，请重新记录"))
      (unless (cl-find (alist-get 'id item) org-museum-knowledge--experiences
                       :key (lambda (entry) (alist-get 'id entry)) :test #'equal)
        (push item org-museum-knowledge--experiences)
        (org-museum-knowledge--persist-derived))
      (org-museum--start-background-job 'export-all nil)
      (message "失败经验已确认，站点更新已排队"))))

;;;###autoload
(defun org-museum-settle-task (problem result wrong-attempt)
  "Preview a reusable experience and explicitly approve public sedimentation."
  (interactive
   (list (read-string "完成的问题：")
         (read-string "实际结果及验证：")
         (read-string "失败尝试（可留空）：")))
  (unless (and (buffer-file-name) (org-museum--file-in-project-p (buffer-file-name)))
    (user-error "结算任务前请先打开 Org 原笔记"))
  (when (or (string-empty-p (string-trim problem))
            (string-empty-p (string-trim result)))
    (user-error "请填写问题和实际结果"))
  (org-museum-knowledge--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let* ((file (expand-file-name (buffer-file-name)))
         (page (org-museum-knowledge--page-for-file file))
         (hash (org-museum-knowledge--file-hash file))
         (item `((id . ,(secure-hash 'sha256
                                     (concat file hash problem result)))
                 (file . ,file)
                 (pageId . ,(and page (org-museum-page-id page)))
                 (sourceHash . ,hash)
                 (problem . ,(string-trim problem))
                 (result . ,(string-trim result))
                 (wrongAttempt . ,(string-trim wrong-attempt))
                 (verification . "user-confirmed")
                 (createdAt . ,(format-time-string "%FT%T%z"))
                 (published . t))))
    (unless page (user-error "原笔记尚未索引"))
    (with-current-buffer (get-buffer-create "*Org Museum 经验预览*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "* 经验候选\n\n问题：%s\n实际结果：%s\n失败尝试：%s\n\n来源：%s\n原文 Hash：%s\n\n确认后会进入本地派生层及公开导出。\n"
                        problem result wrong-attempt file hash))
        (org-mode)
        (view-mode 1))
      (display-buffer (current-buffer)))
    (when (yes-or-no-p "沉淀并公开这条经验？")
      (unless (equal hash (org-museum-knowledge--file-hash file))
        (user-error "审核期间原笔记发生变化，请重新结算"))
      (unless (cl-find (alist-get 'id item) org-museum-knowledge--experiences
                       :key (lambda (entry) (alist-get 'id entry)) :test #'equal)
        (push item org-museum-knowledge--experiences)
        (org-museum-knowledge--persist-derived))
      (org-museum--start-background-job 'export-all nil)
      (message "经验已确认，站点更新已排队"))))

(defun org-museum-ai-queue ()
  "Show a compact view of the analysis queue."
  (interactive)
  (org-museum-knowledge--ensure)
  (with-current-buffer (get-buffer-create "*Org Museum AI 队列*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Mode: %s%s\n待分析：%d  已完成：%d  失败：%d\n\n"
                      org-museum-knowledge-work-mode
                      (if org-museum-knowledge--paused " (paused)" "")
                      (cl-count "dirty" org-museum-knowledge--queue
                                :key (lambda (job) (alist-get 'status job))
                                :test #'equal)
                      (cl-count "done" org-museum-knowledge--queue
                                :key (lambda (job) (alist-get 'status job))
                                :test #'equal)
                      (cl-count "failed" org-museum-knowledge--queue
                                :key (lambda (job) (alist-get 'status job))
                                :test #'equal)))
      (dolist (job org-museum-knowledge--queue)
        (insert (format "%s  %s%s\n"
                        (alist-get 'status job)
                        (file-name-nondirectory (alist-get 'file job))
                        (if-let* ((err (alist-get 'error job)))
                            (concat " — " err) ""))))
      (special-mode))
    (display-buffer (current-buffer))))

(provide 'org-museum-knowledge)
;;; org-museum-knowledge.el ends here
