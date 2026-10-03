;;; org-museum-context.el --- Local context graph for Org Museum -*- lexical-binding: t -*-

;; A transient view over the existing index and private knowledge layer.

(require 'button)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'svg)
(require 'org-museum-knowledge)

(defgroup org-museum-context nil
  "Local, source-backed context views for Org Museum."
  :group 'org-museum-knowledge)

(defcustom org-museum-context-max-pages 16
  "Maximum page nodes in a two-hop context graph, including the centre."
  :type 'integer :group 'org-museum-context)

(defcustom org-museum-context-max-first-hop-pages 8
  "Maximum page nodes in the first hop, including the centre."
  :type 'integer :group 'org-museum-context)

(defcustom org-museum-context-max-experiences 6
  "Maximum confirmed experience nodes in one context graph."
  :type 'integer :group 'org-museum-context)

(defvar-local org-museum-context--anchor-id nil)
(defvar-local org-museum-context--query nil)
(defvar-local org-museum-context--section nil)
(defvar-local org-museum-context--depth 1)
(defvar-local org-museum-context--selected-id nil)
(defvar-local org-museum-context--show-evidence nil)
(defvar-local org-museum-context--data nil)

(defun org-museum-context--node (id kind label depth &rest properties)
  (append `((id . ,id) (kind . ,kind) (label . ,label) (depth . ,depth))
          properties))

(defun org-museum-context--page-text (page)
  (concat (or (org-museum-page-title page) "") " "
          (or (org-museum-page-description page) "")))

(defun org-museum-context--best-page (query)
  "Find the strongest indexed page for a task-only QUERY."
  (let ((experience-scores (make-hash-table :test 'equal)) best)
    (dolist (item org-museum-knowledge--experiences)
      (when (and (eq (alist-get 'published item) t)
                 (org-museum-knowledge--experience-current-p item))
        (cl-incf (gethash (alist-get 'pageId item) experience-scores 0)
                 (* 2 (org-museum-knowledge--score
                       query (concat (or (alist-get 'problem item) "") " "
                                     (or (alist-get 'result item) "")))))))
    (maphash
     (lambda (_id page)
       (let* ((id (org-museum-page-id page))
              (score (+ (org-museum-knowledge--score
                         query (org-museum-context--page-text page))
                        (gethash id experience-scores 0))))
         (when (and (> score 0)
                    (or (null best) (> score (car best))
                        (and (= score (car best))
                             (string< id (org-museum-page-id (cdr best))))))
           (setq best (cons score page)))))
     (org-museum-index-pages org-museum--index))
    (cdr best)))

(defun org-museum-context--current-section ()
  "Return the current Org heading and source line, when there is one."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (when (ignore-errors (org-back-to-heading t))
        (list (org-get-heading t t t t)
              (line-number-at-pos (point)))))))

(defun org-museum-context--neighbor-candidates (page query relations)
  "Return nearby indexed pages, best relationship first."
  (let* ((pages (org-museum-index-pages org-museum--index))
         (id (org-museum-page-id page))
         (candidates (make-hash-table :test 'equal)))
    (dolist (target-id (append (org-museum-page-links-to page)
                               (org-museum-page-linked-from page)))
      (when (and (not (equal target-id id)) (gethash target-id pages))
        (puthash target-id nil candidates)))
    (dolist (relation relations)
      (let ((target-id
             (cond ((equal id (alist-get 'sourcePageId relation))
                    (alist-get 'targetPageId relation))
                   ((equal id (alist-get 'targetPageId relation))
                    (alist-get 'sourcePageId relation)))))
        (when (and target-id (not (equal target-id id))
                   (gethash target-id pages))
          (let ((old (gethash target-id candidates)))
            (when (or (null old)
                      (> (or (alist-get 'confidence relation) 0)
                         (or (alist-get 'confidence old) 0)))
              (puthash target-id relation candidates))))))
    (let (result)
      (maphash
       (lambda (target-id relation)
         (let* ((target (gethash target-id pages))
                (text-score (org-museum-knowledge--score
                             query (org-museum-context--page-text target)))
                (score (+ (* 2 text-score)
                          (org-museum-knowledge--relation-boost relation)
                          (if (or (member target-id (org-museum-page-links-to page))
                                  (member target-id (org-museum-page-linked-from page)))
                              2 0))))
           (push (list target-id relation score) result)))
       candidates)
      (sort result (lambda (a b)
                     (if (= (nth 2 a) (nth 2 b))
                         (string< (car a) (car b))
                       (> (nth 2 a) (nth 2 b))))))))

(defun org-museum-context--data (anchor query depth &optional section)
  "Build a bounded, private graph around ANCHOR for QUERY.
DEPTH is one or two.  Nodes and edges are a view, never stored as facts."
  (unless (and anchor (memq depth '(1 2)))
    (user-error "请选择已索引原笔记，并指定一层或两层关系"))
  (let* ((pages (org-museum-index-pages org-museum--index))
         (relations (org-museum-knowledge--effective-relations))
         (anchor-id (org-museum-page-id anchor))
         (search-query (or query (car section)
                           (org-museum-page-title anchor)))
         (seen (make-hash-table :test 'equal))
         (edge-seen (make-hash-table :test 'equal))
         (page-count 1)
         (experience-count 0)
         (frontier (list anchor-id))
         nodes edges)
    (puthash anchor-id t seen)
    (push (org-museum-context--node
           anchor-id 'page (org-museum-page-title anchor) 0
           (cons 'file (org-museum-page-path anchor))
           (cons 'pageId anchor-id)
           (cons 'item anchor))
          nodes)
    (when (and query (not (string-empty-p (string-trim query))))
      (push (org-museum-context--node
             "context:task" 'task (string-trim query) 1
             (cons 'summary (string-trim query))) nodes)
      (push '((from . "context:task") (to . nil)
              (label . "当前任务") (kind . "context")) edges)
      (setf (alist-get 'to (car edges)) anchor-id))
    (when section
      (push (org-museum-context--node
             "context:section" 'section (car section) 1
             (cons 'file (org-museum-page-path anchor))
             (cons 'line (cadr section))) nodes)
      (push `((from . ,anchor-id) (to . "context:section")
              (label . "当前章节") (kind . "context")) edges))
    (dotimes (ring depth)
      (let (next)
        (dolist (page-id frontier)
          (let ((page (gethash page-id pages)))
            (when page
              (dolist (candidate (org-museum-context--neighbor-candidates
                                  page search-query relations))
                (pcase-let ((`(,target-id ,relation ,_) candidate))
                  (when (and (< page-count org-museum-context-max-pages)
                             (or (> ring 0)
                                 (< page-count
                                    org-museum-context-max-first-hop-pages))
                             (not (gethash target-id seen)))
                    (puthash target-id t seen)
                    (cl-incf page-count)
                    (let ((target (gethash target-id pages)))
                      (push (org-museum-context--node
                             target-id 'page (org-museum-page-title target)
                             (1+ ring)
                             (cons 'file (org-museum-page-path target))
                             (cons 'pageId target-id)
                             (cons 'item target)) nodes))
                    (push target-id next))
                  (when (gethash target-id seen)
                    (let ((key (sort (list page-id target-id) #'string<)))
                      (unless (gethash key edge-seen)
                        (puthash key t edge-seen)
                        (push `((from . ,page-id) (to . ,target-id)
                                (label . ,(if relation
                                              (org-museum-knowledge--relation-label relation)
                                            "显式链接"))
                                (kind . ,(if relation "semantic" "org-link"))
                                (relation . ,relation)
                                (conflict . ,(and relation
                                                  (org-museum-knowledge--pair-conflicting-p
                                                   (alist-get 'sourcePageId relation)
                                                   (alist-get 'targetPageId relation)
                                                   relations))))
                              edges)))))))))
        (setq frontier (nreverse next))))
    (dolist (page-node (seq-filter
                        (lambda (node)
                          (and (eq (alist-get 'kind node) 'page)
                               (< (alist-get 'depth node) depth)))
                        (reverse nodes)))
      (let* ((page-id (alist-get 'pageId page-node))
             (items (cl-remove-if-not
                     (lambda (item)
                       (and (eq (alist-get 'published item) t)
                            (equal page-id (alist-get 'pageId item))
                            (org-museum-knowledge--experience-current-p item)))
                     org-museum-knowledge--experiences)))
        (setq items
              (sort items
                    (lambda (a b)
                      (> (+ (org-museum-knowledge--experience-score search-query a)
                            (if (org-museum-knowledge--failure-p a) 4 0))
                         (+ (org-museum-knowledge--experience-score search-query b)
                            (if (org-museum-knowledge--failure-p b) 4 0))))))
        (dolist (item (seq-take items 3))
          (when (< experience-count org-museum-context-max-experiences)
            (cl-incf experience-count)
            (let* ((id (concat "experience:"
                               (or (alist-get 'id item)
                                   (secure-hash 'sha256
                                                (concat (or (alist-get 'file item) "")
                                                        (or (alist-get 'problem item) ""))))))
                   (failure (org-museum-knowledge--has-failed-attempt-p item)))
              (push (org-museum-context--node
                     id (if failure 'failure 'experience)
                     (alist-get 'problem item) (1+ (alist-get 'depth page-node))
                     (cons 'file (alist-get 'file item))
                     (cons 'line (alist-get 'line (alist-get 'evidence item)))
                     (cons 'item item)) nodes)
              (push `((from . ,page-id) (to . ,id)
                      (label . ,(if failure "失败经验" "已确认经验"))
                      (kind . "experience")) edges))))))
    (when (fboundp 'org-museum-derived--relevant)
      (dolist (scored (seq-take
                       (org-museum-derived--relevant search-query anchor-id) 3))
        (let* ((item (cdr scored))
               (id (concat "derived:" (alist-get 'id item)))
               (sources (alist-get 'sources item))
               (present (cl-remove-if-not
                         (lambda (source)
                           (gethash (alist-get 'pageId source) seen))
                         sources)))
          (when present
            (push (org-museum-context--node
                   id 'derived (alist-get 'claim item) 1
                   (cons 'file (alist-get 'file (car sources)))
                   (cons 'line (alist-get 'line (car sources)))
                   (cons 'item item)) nodes)
            (dolist (source present)
              (push `((from . ,(alist-get 'pageId source)) (to . ,id)
                      (label . "派生自") (kind . "derived")) edges))))))
    (let ((analysis (org-museum-knowledge--analysis
                     (org-museum-page-path anchor))))
      (when (and analysis
                 (equal (alist-get 'hash analysis)
                        (org-museum-knowledge--file-hash
                         (org-museum-page-path anchor))))
        (push (org-museum-context--node
               "context:analysis" 'analysis "AI 分析（未验证）" 1
               (cons 'file (org-museum-page-path anchor))
               (cons 'item analysis)) nodes)
        (push `((from . ,anchor-id) (to . "context:analysis")
                (label . "分析摘要") (kind . "analysis")) edges)))
    (list :anchor anchor-id :query query :depth depth
          :nodes (nreverse nodes) :edges (nreverse edges))))

(defun org-museum-context--color (kind)
  (pcase kind
    ('page "#456b91") ('failure "#b6534f")
    ('experience "#528069") ('analysis "#9a7440")
    ('derived "#6a718c")
    ('task "#796a9b") ('section "#708493")
    (_ "#667482")))

(defun org-museum-context--positions (nodes)
  (let ((positions (make-hash-table :test 'equal)))
    (dolist (depth '(0 1 2 3))
      (let* ((ring (seq-filter
                    (lambda (node) (= depth (alist-get 'depth node))) nodes))
             (count (length ring))
             (radius (pcase depth (0 0) (1 175) (2 285) (_ 325))))
        (cl-loop for node in ring for i from 0
                 for angle = (- (* 2 float-pi (/ (float i) (max 1 count)))
                                (/ float-pi 2))
                 for stagger = (if (and (> depth 0) (> count 8))
                                   (if (cl-evenp i) -24 24) 0)
                 do (puthash (alist-get 'id node)
                             (cons (+ 520 (* (+ radius stagger) (cos angle)))
                                   (+ 340 (* (+ radius stagger) (sin angle))))
                             positions))))
    positions))

(defun org-museum-context--svg (data)
  "Create the visual graph for DATA, with no remote assets or scripts."
  (let* ((nodes (plist-get data :nodes))
         (edges (plist-get data :edges))
         (positions (org-museum-context--positions nodes))
         (svg (svg-create 1040 680 :background "#f7f5ef")))
    (svg-rectangle svg 0 0 1040 680 :fill "#f7f5ef")
    (dolist (edge edges)
      (let ((a (gethash (alist-get 'from edge) positions))
            (b (gethash (alist-get 'to edge) positions))
            (relation (alist-get 'relation edge)))
        (when (and a b)
          (let ((stroke (if (or (alist-get 'conflict edge)
                                (equal (alist-get 'type relation) "contradicts"))
                            "#b6534f" "#a8b1b6")))
            (svg-line svg (car a) (cdr a) (car b) (cdr b)
                      :stroke stroke
                      :stroke-width (if relation 2.5 1.5))
            (when (or relation (<= (length nodes) 8))
              (svg-text svg (if relation
				(org-museum-knowledge--relation-label relation)
                              (alist-get 'label edge))
			:x (/ (+ (car a) (car b)) 2)
			:y (/ (+ (cdr a) (cdr b)) 2)
			:font-size 12 :fill "#394c5b"
			:text-anchor "middle")
              (let* ((source (gethash (alist-get 'sourcePageId relation) positions))
                     (target (gethash (alist-get 'targetPageId relation) positions)))
		(when (and source target)
                  (let* ((dx (- (car target) (car source)))
			 (dy (- (cdr target) (cdr source)))
			 (distance (max 1 (sqrt (+ (* dx dx) (* dy dy)))))
			 (ux (/ dx distance)) (uy (/ dy distance))
			 (tipx (- (car target) (* 25 ux)))
			 (tipy (- (cdr target) (* 25 uy)))
			 (basex (- tipx (* 11 ux)))
			 (basey (- tipy (* 11 uy))))
                    (svg-polygon
                     svg (list (cons tipx tipy)
                               (cons (+ basex (* 5 uy)) (- basey (* 5 ux)))
                               (cons (- basex (* 5 uy)) (+ basey (* 5 ux))))
                     :fill stroke)))))))))
    (dolist (node nodes)
      (let* ((pos (gethash (alist-get 'id node) positions))
             (kind (alist-get 'kind node))
             (label (truncate-string-to-width
                     (or (alist-get 'label node) "") 12 nil nil "…")))
        (when pos
          (svg-circle svg (car pos) (cdr pos)
                      (if (= (alist-get 'depth node) 0) 31 22)
                      :fill (org-museum-context--color kind)
                      :stroke "#ffffff" :stroke-width 2)
          (svg-text svg label :x (car pos) :y (+ (cdr pos) 43)
                    :font-size 13 :fill "#263746" :text-anchor "middle"))))
    (svg-image svg :ascent 'center)))

(defvar org-museum-context-graph-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "x") #'org-museum-context-expand)
    (define-key map (kbd "c") #'org-museum-context-collapse)
    (define-key map (kbd "g") #'org-museum-context-refresh)
    (define-key map (kbd "o") #'org-museum-context-open-source)
    (define-key map (kbd "e") #'org-museum-context-toggle-evidence)
    (define-key map (kbd "n") #'org-museum-context-next-node)
    (define-key map (kbd "p") #'org-museum-context-previous-node)
    map))

(define-derived-mode org-museum-context-graph-mode special-mode "知识上下文"
  "Local, temporary knowledge graph.  RET selects a node below the image."
  (setq-local truncate-lines t))

(defun org-museum-context--readable-markdown (source)
  "Return SOURCE as readable Emacs text without exposing Markdown markers."
  (let ((fence nil)
        (lines nil))
    (dolist (line (split-string (or source "") "\n"))
      (cond
       ((string-match-p "^[[:space:]]*\\(```\\|~~~\\)" line)
        (setq fence (not fence)))
       (fence
        (push (propertize (concat "    " line) 'face 'fixed-pitch) lines))
       ((string-match-p "^[[:space:]]*|?[[:space:]]*:?-[-:|[:space:]]+$" line)
        nil)
       (t
        (let ((heading (string-match "^[[:space:]]*#+[[:space:]]+" line)))
          (when heading (setq line (substring line (match-end 0))))
          (setq line (replace-regexp-in-string
                      "^[[:space:]]*[-*+][[:space:]]+" "  • " line))
          (setq line (replace-regexp-in-string
                      "^[[:space:]]*>[[:space:]]*" "│ " line))
          (setq line (replace-regexp-in-string
                      "!\\[\\([^]]*\\)\\](\\([^)]*\\))" "图片：\\1（\\2）" line))
          (setq line (replace-regexp-in-string
                      "\\[\\([^]]+\\)\\](\\([^)]*\\))" "\\1（\\2）" line))
          (setq line (replace-regexp-in-string
                      "\\*\\*\\([^*]+\\)\\*\\*\\|__\\([^_]+\\)__"
                      (lambda (match)
                        (propertize (substring match 2 -2) 'face 'bold)) line))
          (setq line (replace-regexp-in-string
                      "`\\([^`]+\\)`"
                      (lambda (match)
                        (propertize (substring match 1 -1) 'face 'fixed-pitch))
                      line))
          (when (string-match-p "^[[:space:]]*|" line)
            (setq line (replace-regexp-in-string "|" " │ " line)))
          (push (if heading (propertize line 'face 'bold) line) lines)))))
    (string-join (nreverse lines) "\n")))

(defun org-museum-context--detail (node data)
  (let* ((kind (alist-get 'kind node))
         (item (alist-get 'item node))
         (id (alist-get 'id node))
         (related (cl-remove-if-not
                   (lambda (edge)
                     (or (equal id (alist-get 'from edge))
                         (equal id (alist-get 'to edge))))
                   (plist-get data :edges))))
    (insert (format "%s · %s\n"
                    (alist-get 'label node)
                    (pcase kind
                      ('page "原笔记") ('failure "失败经验")
                      ('experience "已确认经验") ('analysis "AI 推断")
                      ('derived "已确认派生知识")
                      ('task "当前任务") ('section "当前章节"))))
    (pcase kind
      ((or 'failure 'experience)
       (insert (format "解决方法：%s\n验证：%s\n"
                       (or (alist-get 'result item) "")
                       (org-museum-knowledge--verification-label item)))
       (when-let* ((wrong (alist-get 'wrongAttempt item)))
         (unless (string-empty-p wrong)
           (insert (format "失败尝试：%s\n" wrong))))
       (when-let* ((cause (alist-get 'cause item)))
         (insert (format "原因：%s\n" cause)))
       (when-let* ((scope (alist-get 'scope item)))
         (insert (format "范围：%s\n" scope)))
       (when org-museum-context--show-evidence
         (when-let* ((excerpt (alist-get 'excerpt (alist-get 'evidence item))))
           (insert (format "依据摘录：\n%s\n" excerpt)))))
      ('derived
       (insert (format "组合结论：%s\n状态：%s\n验证计划：%s\n"
                       (alist-get 'claim item)
                       (if (org-museum-derived--verified-current-p item)
                           "有原笔记执行结果（未重新执行）"
                         "用户确认，尚未见当前执行结果")
                       (alist-get 'verificationPlan item)))
       (dolist (source (alist-get 'sources item))
         (insert (format "派生自：%s\n"
                         (org-museum-derived--source-summary source)))
         (when org-museum-context--show-evidence
           (insert (format "来源片段：%s\n" (alist-get 'excerpt source))))))
      ('analysis
       (insert (format "模型：%s\n生成时间：%s\n未经过执行验证。\n"
                       (or (alist-get 'model item) "未知")
                       (or (alist-get 'generatedAt item) "未知")))
       (when org-museum-context--show-evidence
         (insert "分析内容：\n"
                 (org-museum-context--readable-markdown
                  (alist-get 'summary item)) "\n")))
      ('page
       (when-let* ((description (org-museum-page-description item)))
         (insert (format "%s\n" description)))))
    (when-let* ((file (alist-get 'file node)))
      (insert (format "来源：%s%s\n" file
                      (if-let* ((line (alist-get 'line node)))
                          (format "，第 %d 行" line) ""))))
    (dolist (edge related)
      (when-let* ((relation (alist-get 'relation edge)))
        (insert (org-museum-knowledge--relation-summary relation))
        (when (alist-get 'conflict edge)
          (insert "待复核：关系存在冲突。\n"))))))

(defun org-museum-context--render (&optional focus-detail)
  (let* ((inhibit-read-only t)
         (anchor (gethash org-museum-context--anchor-id
                          (org-museum-index-pages org-museum--index)))
         (data (org-museum-context--data
                anchor org-museum-context--query org-museum-context--depth
                org-museum-context--section))
         (nodes (plist-get data :nodes))
         (selected (or (cl-find org-museum-context--selected-id nodes
                                :key (lambda (node) (alist-get 'id node))
                                :test #'equal)
                       (car nodes))))
    (setq org-museum-context--data data
          org-museum-context--selected-id (alist-get 'id selected))
    (erase-buffer)
    (insert (format "当前上下文：%s%s\n"
                    (org-museum-page-title anchor)
                    (if org-museum-context--query
                        (format " · %s" org-museum-context--query) "")))
    (insert (format "%d 层 · %d 个节点 · %d 条连接\n"
                    org-museum-context--depth (length nodes)
                    (length (plist-get data :edges))))
    (insert "x 展开   c 收起   n/p 切换节点   o 打开来源   e 查看依据   g 刷新   q 关闭\n\n")
    (when (image-type-available-p 'svg)
      (insert-image (org-museum-context--svg data))
      (insert "\n\n"))
    (dolist (node nodes)
      (let ((id (alist-get 'id node)))
        (insert-text-button
         (format "%s %s%s"
                 (if (equal id org-museum-context--selected-id) "●" "○")
                 (make-string (* 2 (alist-get 'depth node)) ?\s)
                 (alist-get 'label node))
         'follow-link t
         'action (lambda (_button)
                   (setq org-museum-context--selected-id id
                         org-museum-context--show-evidence nil)
                   (org-museum-context--render t)))
        (insert "\n")))
    (let ((detail-start (point)))
      (insert "\n所选节点\n")
      (org-museum-context--detail selected data)
      (goto-char (if focus-detail detail-start (point-min))))))

(defun org-museum-context--cycle-node (step)
  (let* ((nodes (plist-get org-museum-context--data :nodes))
         (ids (mapcar (lambda (node) (alist-get 'id node)) nodes))
         (index (or (cl-position org-museum-context--selected-id ids
                                 :test #'equal) 0)))
    (when ids
      (setq org-museum-context--selected-id
            (nth (mod (+ index step) (length ids)) ids)
            org-museum-context--show-evidence nil)
      (org-museum-context--render t))))

(defun org-museum-context-next-node ()
  "Select the next local context node."
  (interactive)
  (org-museum-context--cycle-node 1))

(defun org-museum-context-previous-node ()
  "Select the previous local context node."
  (interactive)
  (org-museum-context--cycle-node -1))

(defun org-museum-context-expand ()
  "Expand the local context graph from one hop to two."
  (interactive)
  (setq org-museum-context--depth 2)
  (org-museum-context--render))

(defun org-museum-context-collapse ()
  "Return the local context graph to one hop."
  (interactive)
  (setq org-museum-context--depth 1)
  (org-museum-context--render))

(defun org-museum-context-refresh ()
  "Rebuild the context graph from the current index and private layer."
  (interactive)
  (org-museum-knowledge--ensure)
  (org-museum-index-build)
  (org-museum-context--render))

(defun org-museum-context-open-source ()
  "Open the selected node's original Org source and evidence line."
  (interactive)
  (let* ((node (cl-find org-museum-context--selected-id
                        (plist-get org-museum-context--data :nodes)
                        :key (lambda (item) (alist-get 'id item)) :test #'equal))
         (file (alist-get 'file node))
         (line (alist-get 'line node)))
    (unless (and file (file-regular-p file))
      (user-error "这个上下文节点没有原文件"))
    (find-file-other-window file)
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun org-museum-context-toggle-evidence ()
  "Toggle the selected node's private evidence in the graph detail."
  (interactive)
  (setq org-museum-context--show-evidence
        (not org-museum-context--show-evidence))
  (org-museum-context--render t))

;;;###autoload
(defun org-museum-context-graph (&optional query)
  "Show a one-hop context graph for this note, tutorial section or task.
With a prefix, prompt for a task.  Use x in the view to expand one more hop."
  (interactive (list (when current-prefix-arg
                       (read-string "当前任务/问题："))))
  (org-museum-knowledge--ensure)
  (unless org-museum--index (org-museum-index-build))
  (let* ((current (and (buffer-file-name)
                       (org-museum--file-in-project-p (buffer-file-name))
                       (org-museum-knowledge--page-for-file
                        (buffer-file-name))))
         (task (or query
                   (unless current
                     (read-string "当前任务/问题："))))
         (anchor (or current
                     (and (stringp task)
                          (org-museum-context--best-page task))
                     (and (called-interactively-p 'interactive)
                          (> (hash-table-count
                              (org-museum-index-pages org-museum--index)) 0)
                          (gethash (org-museum-knowledge--choose-target-page)
                                   (org-museum-index-pages org-museum--index)))))
         (section (and current (org-museum-context--current-section)))
         (context-query (and (stringp task)
                             (not (string-empty-p (string-trim task)))
                             (string-trim task))))
    (unless anchor
      (user-error "没有与当前任务匹配的已索引笔记"))
    (with-current-buffer (get-buffer-create "*Org Museum 上下文图谱*")
      (org-museum-context-graph-mode)
      (setq org-museum-context--anchor-id (org-museum-page-id anchor)
            org-museum-context--query context-query
            org-museum-context--section section
            org-museum-context--depth 1
            org-museum-context--selected-id nil
            org-museum-context--show-evidence nil)
      (org-museum-context--render)
      (display-buffer (current-buffer)))))

(provide 'org-museum-context)
;;; org-museum-context.el ends here
