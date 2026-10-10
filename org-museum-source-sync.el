;;; org-museum-source-sync.el --- Save-to-GitHub source sync -*- lexical-binding: t; -*-
(require 'json)
(require 'subr-x)
(require 'org-museum-pipeline)

(defgroup org-museum-source-sync nil "Sync source notes after saving." :group 'org-museum)
(defcustom org-museum-source-sync-root nil "Org-notes Git checkout." :type 'directory)
(defcustom org-museum-source-sync-python "python" "Python executable." :type 'string)
(defcustom org-museum-source-sync-delay 10 "Seconds after the last save." :type 'number)
(defcustom org-museum-source-sync-script
  (expand-file-name "tools/museum_pipeline.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Shared source validator and synchronizer." :type 'file)
(defvar org-museum-source-sync--timer nil)
(defvar org-museum-source-sync--process nil)
(defvar org-museum-source-sync--pending nil)
(defvar org-museum-source-sync--retry 0)
(defvar org-museum-source-sync--halted nil)

(defun org-museum-source-sync--managed-p (file)
  "Whether FILE belongs to the configured source namespaces."
  (and org-museum-source-sync-root file
       (not (file-symlink-p file))
       (cl-some (lambda (name)
                  (file-in-directory-p file (expand-file-name name org-museum-source-sync-root)))
                '("notes" "note-assets"))))

(defun org-museum-source-sync--schedule (seconds)
  (when (timerp org-museum-source-sync--timer)
    (cancel-timer org-museum-source-sync--timer))
  (setq org-museum-source-sync--timer
        (run-at-time seconds nil #'org-museum-source-sync-now)))

(defun org-museum-source-sync--saved ()
  (when (org-museum-source-sync--managed-p buffer-file-name)
    (setq org-museum-source-sync--pending t)
    (unless org-museum-source-sync--halted
      (org-museum-source-sync--schedule org-museum-source-sync-delay))))

(defun org-museum-source-sync--sentinel (process _event)
  (when (memq (process-status process) '(exit signal))
    (setq org-museum-source-sync--process nil)
    (let* ((result
            (with-current-buffer (process-buffer process)
              (goto-char (point-min))
              (condition-case nil
                  (let ((json-object-type 'alist)) (json-read))
                (error nil))))
           (error-text (or (alist-get 'error result) "sync: subprocess failed")))
      (if (= (process-exit-status process) 0)
          (progn
            (setq org-museum-source-sync--retry 0)
            (message "知识库源笔记同步：%s %s"
                     (alist-get 'status result) (or (alist-get 'commit result) ""))
            (when (and org-museum-source-sync-mode org-museum-source-sync--pending)
              (org-museum-source-sync--schedule org-museum-source-sync-delay)))
        (setq org-museum-source-sync--pending t)
        (if (and org-museum-source-sync-mode
                 (or (string-prefix-p "network:" error-text)
                     (and (string-prefix-p "retry:" error-text)
                          (< org-museum-source-sync--retry 3))))
            (progn
              (cl-incf org-museum-source-sync--retry)
              (org-museum-source-sync--schedule
               (min 300 (* 15 (expt 2 (min 5 org-museum-source-sync--retry))))))
          (setq org-museum-source-sync--halted t))
        (message "知识库同步暂停，本机内容已保留：%s" error-text)))))

(defun org-museum-source-sync-now ()
  "Sync pending managed notes; an interactive call retries a paused sync."
  (interactive)
  (when (called-interactively-p 'interactive)
    (setq org-museum-source-sync--halted nil
          org-museum-source-sync--pending t))
  (setq org-museum-source-sync--timer nil)
  (when (and org-museum-source-sync--pending
             (not org-museum-source-sync--halted)
             (not (process-live-p org-museum-source-sync--process)))
    (let ((buffer (get-buffer-create "*Org Museum Source Sync*")))
      (with-current-buffer buffer (erase-buffer))
      (setq org-museum-source-sync--pending nil)
      (condition-case err
          (setq org-museum-source-sync--process
                (make-process
                 :name "org-museum-source-sync" :buffer buffer :noquery t
                 :connection-type 'pipe :coding 'utf-8-unix
                 :command (list org-museum-source-sync-python org-museum-source-sync-script
                                "sync" "--root" org-museum-source-sync-root)
                 :sentinel #'org-museum-source-sync--sentinel))
        (error
         (setq org-museum-source-sync--pending t org-museum-source-sync--halted t)
         (message "知识库同步未启动：%s" (error-message-string err)))))))

(define-minor-mode org-museum-source-sync-mode
  "Automatically submit managed source notes after saving."
  :global t :group 'org-museum-source-sync
  (if org-museum-source-sync-mode
      (progn
        (unless (and org-museum-source-sync-root
                     (file-exists-p (expand-file-name "museum.json" org-museum-source-sync-root)))
          (setq org-museum-source-sync-mode nil)
          (user-error "请先配置 Actions 知识库 checkout"))
        (add-hook 'after-save-hook #'org-museum-source-sync--saved)
        ;; Recover saved changes across Emacs restarts by inspecting Git again.
        (setq org-museum-source-sync--pending t org-museum-source-sync--halted nil)
        (org-museum-source-sync--schedule org-museum-source-sync-delay))
    (remove-hook 'after-save-hook #'org-museum-source-sync--saved)
    (when (timerp org-museum-source-sync--timer)
      (cancel-timer org-museum-source-sync--timer))))

(provide 'org-museum-source-sync)
;;; org-museum-source-sync.el ends here
