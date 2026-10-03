;;; org-museum-test.el --- Tests for org-museum -*- lexical-binding: t; -*-

(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8)

(require 'ert)
(require 'cl-lib)
(require 'org-museum)

(defconst org-museum-test--repo-root
  (file-name-directory
   (directory-file-name (file-name-directory load-file-name)))
  "Repository root used by fixture tests.")

(defun org-museum-test--count-occurrences (needle haystack)
  "Return the number of non-overlapping NEEDLE occurrences in HAYSTACK."
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun org-museum-test--file-string (file)
  "Return FILE contents as a string for byte-preservation assertions."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun org-museum-test--unique-sibling-path (root name)
  "Return a process-safe sibling of ROOT using NAME as its readable prefix."
  (expand-file-name
   (format "%s-%s" name
           (file-name-nondirectory (directory-file-name root)))
   (file-name-directory (directory-file-name root))))

(ert-deftest org-museum-publish-fixtures-use-unique-sibling-paths ()
  "Concurrent publish fixtures must not share one global temporary checkout."
  (let* ((first (file-name-as-directory
                 (make-temp-file "org-museum-publish-isolation-a-" t)))
         (second (file-name-as-directory
                  (make-temp-file "org-museum-publish-isolation-b-" t)))
         (first-publish
          (org-museum-test--unique-sibling-path first "published-site"))
         (second-publish
          (org-museum-test--unique-sibling-path second "published-site")))
    (unwind-protect
        (progn
          (should-not (equal first-publish second-publish))
          (should-not (file-in-directory-p first-publish first))
          (should-not (file-in-directory-p second-publish second))
          (should (equal (file-name-directory first-publish)
                         (file-name-directory (directory-file-name first))))
          (should (equal (file-name-directory second-publish)
                         (file-name-directory (directory-file-name second)))))
      (delete-directory first t)
      (delete-directory second t))))

(defun org-museum-test--page (id title modified &optional category tags status path)
  "Build a test page with ID, TITLE, and MODIFIED."
  (make-org-museum-page
   :id id
   :title title
   :path (or path (concat id ".org"))
   :tags (or tags '())
   :category (or category "测试")
   :modified modified
   :links-to nil
   :linked-from nil
   :theme ""
   :status (or status "published")))

(defun org-museum-test--tree-hashes (root)
  "Return stable relative SHA256 records for all regular files below ROOT."
  (mapcar
   (lambda (file)
     (cons (replace-regexp-in-string "\\\\" "/" (file-relative-name file root))
           (org-museum--file-content-hash file)))
   (sort (directory-files-recursively root "." nil) #'string<)))

(ert-deftest org-museum-html-escaping-covers-cjk-and-special-characters ()
  (should
   (equal
    (org-museum--html-escape "中文 & <tag> \"引号\"" t)
    "中文 &amp; &lt;tag&gt; &quot;引号&quot;"))
  (let ((encoded (org-museum--json-for-html
                  '((title . "</script><中文>&")))))
    (should-not (string-match-p "</script>" encoded))
    (should (string-match-p "\\\\u003c/script\\\\u003e" encoded))
    (should (string-match-p "中文" encoded))))

(ert-deftest org-museum-pages-sort-by-modified-descending ()
  (let* ((old (org-museum-test--page "old" "旧" 10))
         (new (org-museum-test--page "new" "新" 30))
         (middle (org-museum-test--page "middle" "中" 20))
         (sorted (org-museum--sort-pages-by-modified
                  (list old new middle))))
    (should (equal (mapcar #'org-museum-page-id sorted)
                   '("new" "middle" "old")))))

(ert-deftest org-museum-scan-excludes-build-artifacts-and-invalidates-cache ()
  "Generated fixture notes and changed scan scope must not survive in the index."
  (let* ((root (make-temp-file "museum-scan-scope-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-export-dir "dist/pages")
         (org-museum-shared-export-dir "dist")
         (org-museum--index nil)
         (cache (expand-file-name ".org-museum-index.json" root)))
    (unwind-protect
        (progn
          (dolist (name '("root.org" "pages/note.org" "pages/.#note.org"
                          "output/test.org" "dist/copied.org"))
            (let ((file (expand-file-name name root)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file (insert (format "#+TITLE: %s\n" name)))))
          (should (= 2 (length (org-museum--scan-files))))
          (let ((org-museum-scan-excluded-directories nil))
            (should (= 3 (length (org-museum--scan-files))))
            (org-museum-index-build t)
            (should (org-museum--index-fresh-p cache)))
          (should-not (org-museum--index-fresh-p cache))
          (org-museum-index-build)
          (should (= 2 (hash-table-count (org-museum-index-pages org-museum--index))))
          (delete-file (expand-file-name "pages/note.org" root))
          (setq org-museum--index nil)
          (should-not (org-museum--index-fresh-p cache)))
      (delete-directory root t))))

(ert-deftest org-museum-index-scan-rejects-duplicate-page-ids ()
  (let* ((root (make-temp-file "org-museum-duplicate-id-test-" t))
         (pages-root (expand-file-name "pages" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages"))
    (unwind-protect
        (progn
          (make-directory pages-root t)
          (with-temp-file (expand-file-name "first.org" pages-root)
            (insert "#+TITLE: First\n#+WIKI_ID: duplicate\n#+CATEGORY: Test\n"))
          (with-temp-file (expand-file-name "second.org" pages-root)
            (insert "#+TITLE: Second\n#+WIKI_ID: duplicate\n#+CATEGORY: Test\n"))
          (let ((error-data
                 (should-error (org-museum--index-scan)
                               :type 'org-museum-duplicate-page-id)))
            (should (string-match-p "first\\.org"
                                    (error-message-string error-data)))
            (should (string-match-p "second\\.org"
                                    (error-message-string error-data)))))
      (delete-directory root t))))

(ert-deftest org-museum-index-scan-aborts-on-page-parse-errors ()
  "A malformed page must not disappear from an otherwise successful scan."
  (let* ((root (make-temp-file "org-museum-parse-error-test-" t))
         (pages-root (expand-file-name "pages" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (broken (expand-file-name "broken.org" pages-root)))
    (unwind-protect
        (progn
          (make-directory pages-root t)
          (with-temp-file broken (insert "#+TITLE: Broken\n"))
          (cl-letf (((symbol-function 'org-museum--parse-page-metadata)
                     (lambda (file)
                       (if (equal (expand-file-name file) broken)
                           (error "fixture parse failure")
                         nil))))
            (let ((error-data
                   (should-error (org-museum--index-scan)
                                 :type 'org-museum-index-scan-failed)))
              (should (string-match-p "broken\\.org"
                                      (error-message-string error-data)))
              (should (string-match-p "fixture parse failure"
                                      (error-message-string error-data))))))
      (delete-directory root t))))

(ert-deftest org-museum-index-freshness-covers-every-scanned-file ()
  (let* ((root (make-temp-file "org-museum-scan-scope-test-" t))
         (pages-root (expand-file-name "pages" root))
         (index-file (expand-file-name ".org-museum-index.json" root))
         (root-note (expand-file-name "root-note.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages"))
    (unwind-protect
        (progn
          (make-directory pages-root t)
          (with-temp-file index-file (insert "{}"))
          (set-file-times index-file (seconds-to-time 100))
          (with-temp-file root-note (insert "#+TITLE: Root\n"))
          (set-file-times root-note (seconds-to-time 200))
          (should (member (expand-file-name root-note)
                          (org-museum--scan-files)))
          (should-not (org-museum--index-fresh-p index-file)))
      (delete-directory root t))))

(ert-deftest org-museum-index-rejects-invalid-publish-status ()
  "A status typo must fail the scan instead of publishing the page."
  (let* ((root (make-temp-file "org-museum-status-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (file (expand-file-name "pages/status.org" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (insert "#+TITLE: Status\n#+WIKI_ID: status\n#+WIKI_STATUS: drfat\n"))
          (should-error (org-museum-index-build t)
                        :type 'org-museum-index-scan-failed))
      (delete-directory root t))))

(ert-deftest org-museum-file-link-with-heading-builds-an-edge ()
  (let* ((root (make-temp-file "org-museum-file-heading-test-" t))
         (source (expand-file-name "source.org" root))
         (target (expand-file-name "target note.org" root))
         (pages (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "[[file:target%20note.org::*Section][Target]]"))
          (with-temp-file target (insert "* Section\n"))
          (puthash "source" (make-org-museum-page :id "source" :path source) pages)
          (puthash "target" (make-org-museum-page :id "target" :path target) pages)
          (cl-letf (((symbol-function 'org-museum--org-roam-db-linked-page-ids)
                     (lambda (&rest _) nil)))
            (should (equal '("target")
                           (org-museum--extract-links-from-file source pages)))))
      (delete-directory root t))))

(ert-deftest org-museum-graph-omits-self-links ()
  (let* ((root (make-temp-file "org-museum-self-link-test-" t))
         (source (expand-file-name "source.org" root))
         (pages (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file source (insert "[[wiki:source]]"))
          (puthash "source" (make-org-museum-page :id "source" :path source) pages)
          (cl-letf (((symbol-function 'org-museum--org-roam-db-linked-page-ids)
                     (lambda (&rest _) nil)))
            (should-not (org-museum--extract-links-from-file source pages))))
      (delete-directory root t))))

(ert-deftest org-museum-rename-rewrites-file-links-and-keeps-heading-search ()
  (let* ((root (make-temp-file "org-museum-file-rename-test-" t))
         (source (expand-file-name "notes/source.org" root))
         (old (expand-file-name "pages/old note.org" root))
         (new (expand-file-name "pages/new note.org" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (make-directory (file-name-directory old) t)
          (with-temp-file source
            (insert "[[file:../pages/old%20note.org::*Heading][target]]"))
          (with-temp-file old (insert "* Heading"))
          (should (= 1 (org-museum--update-file-links-for-rename old new
                                                                 (list source))))
          (with-temp-buffer
            (insert-file-contents source)
            (should (search-forward
                     "[[file:../pages/new%20note.org::*Heading][target]]" nil t))))
      (delete-directory root t))))

(ert-deftest org-museum-offline-font-system-is-complete-and-semantic ()
  (let* ((css-path (expand-file-name "resources/org-museum.css"
                                     org-museum-test--repo-root))
         (css (with-temp-buffer
                (insert-file-contents css-path)
                (buffer-string))))
    (dolist (name '("NotoSansCJKsc-VF-v2.004.woff2"
                    "NotoSerifCJKsc-VF.woff2"
                    "VictorMono-Roman-v1.564.woff2"
                    "VictorMono-Italic-v1.564.woff2"
                    "OFL-Noto-Sans-CJK.txt"
                    "OFL-Victor-Mono.txt"
                    "SHA256SUMS"))
      (should (file-regular-p
               (expand-file-name (concat "resources/fonts/" name)
                                 org-museum-test--repo-root))))
    (dolist (variable '("--font-reading" "--font-ui"
                        "--font-code" "--font-technical" "--font-display"))
      (should (string-search variable css)))
    (dolist (icon '("book-open.svg" "file-text.svg" "graph.svg"
                    "magnifying-glass.svg" "moon.svg" "sun.svg" "LICENSE"))
      (should (file-regular-p
               (expand-file-name (concat "resources/icons/" icon)
                                 org-museum-test--repo-root))))
    (should (string-search ".org-museum-code {\n  font: inherit;" css))
    (should-not (string-search "JetBrains Mono" css))
    (should-not (string-search "Cascadia Code" css))))

(ert-deftest org-museum-font-deployment-fails-when-a-required-source-is-missing ()
  (cl-letf (((symbol-function 'org-museum--resource-source-path)
             (lambda (_relative) nil)))
    (should-error (org-museum--ensure-fonts-deployed))))

(ert-deftest org-museum-search-description-and-reading-controls-are-exported ()
  (let ((script (org-museum--script-index)))
    (should (string-search "page._searchText=" script))
    (should (string-search "page.description" script))
    (should (string-search "className='resume-remove'" script))
    (should (string-search "objectStore('readingState').delete(record.pageId)" script))
    (should (string-search "if(!remaining)renderResume([])" script))))

(ert-deftest org-museum-cross-buffer-saves-persist-one-index-batch ()
  (let* ((org-museum-root-dir temporary-file-directory)
         (org-museum--pending-save-files (make-hash-table :test #'equal))
         (org-museum--index
          (make-org-museum-index
           :pages (make-hash-table :test #'equal)
           :tags (make-hash-table :test #'equal)
           :categories (make-hash-table :test #'equal)
           :graph (make-hash-table :test #'equal)))
         updates (save-count 0))
    (puthash "one.org" t org-museum--pending-save-files)
    (puthash "two.org" t org-museum--pending-save-files)
    (cl-letf (((symbol-function 'org-museum--on-save-handle-id-change)
               (lambda (_file)))
              ((symbol-function 'org-museum--scan-files)
               (lambda () nil))
              ((symbol-function 'org-museum--index-update-file-in-place)
               (lambda (file) (push file updates)))
              ((symbol-function 'org-museum--index-save)
               (lambda (&rest _) (cl-incf save-count))))
      (org-museum--flush-pending-saves))
    (should (= 2 (length updates)))
    (should (= 1 save-count))
    (should (= 0 (hash-table-count org-museum--pending-save-files)))))

(ert-deftest org-museum-full-link-scan-opens-the-roam-database-once ()
  (let* ((pages (make-hash-table :test #'equal))
         (index (make-org-museum-index
                 :pages pages :tags (make-hash-table :test #'equal)
                 :categories (make-hash-table :test #'equal)
                 :graph (make-hash-table :test #'equal)))
         (opens 0) (closes 0))
    (dotimes (number 3)
      (puthash (number-to-string number)
               (make-org-museum-page :id (number-to-string number)
                                     :path (format "%d.org" number))
               pages))
    (cl-letf (((symbol-function 'org-museum--org-roam-db-path)
               (lambda () "org-roam.db"))
              ((symbol-function 'sqlite-open)
               (lambda (_path) (cl-incf opens) 'db))
              ((symbol-function 'sqlite-close)
               (lambda (_db) (cl-incf closes)))
              ((symbol-function 'org-museum--extract-links-from-file)
               (lambda (&rest _) nil)))
      (org-museum--scan-resolve-links index))
    (should (= 1 opens))
    (should (= 1 closes))))

(ert-deftest org-museum-batched-save-failure-restores-links-and-keeps-work-pending ()
  (let* ((root (make-temp-file "org-museum-save-batch-rollback-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir nil)
         (org-museum--project-save-timer nil)
         (org-museum--project-save-retry-used nil)
         (target (expand-file-name "target.org" root))
         (referrer (expand-file-name "referrer.org" root))
         (org-museum--pending-save-files (make-hash-table :test #'equal))
         (pages (make-hash-table :test #'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages :tags (make-hash-table :test #'equal)
           :categories (make-hash-table :test #'equal)
           :graph (make-hash-table :test #'equal)))
         (retry-count 0))
    (unwind-protect
        (progn
          (with-temp-file target
            (insert "#+TITLE: Target\n#+WIKI_ID: new-id\n"))
          (with-temp-file referrer (insert "[[wiki:old-id]]"))
          (puthash "old-id"
                   (make-org-museum-page :id "old-id" :path target)
                   pages)
          (puthash target t org-museum--pending-save-files)
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'run-with-idle-timer)
                     (lambda (&rest _)
                       (cl-incf retry-count)
                       'fixture-retry-timer))
                    ((symbol-function 'org-museum--index-update-file-in-place)
                     (lambda (_file) (error "fixture failure"))))
            (org-museum--flush-pending-saves))
          (with-temp-buffer
            (insert-file-contents referrer)
            (should (search-forward "[[wiki:old-id]]" nil t))
            (should-not (search-forward "[[wiki:new-id]]" nil t)))
          (should (gethash target org-museum--pending-save-files))
          (should (= retry-count 1))
          (should (eq org-museum--project-save-timer
                      'fixture-retry-timer))
          (setq org-museum--project-save-timer nil)
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'run-with-idle-timer)
                     (lambda (&rest _) (cl-incf retry-count)))
                    ((symbol-function 'org-museum--index-update-file-in-place)
                     (lambda (_file) (error "fixture retry failure"))))
            (org-museum--flush-pending-saves))
          (should (= retry-count 1))
          (should (gethash target org-museum--pending-save-files)))
      (delete-directory root t))))

(ert-deftest org-museum-create-page-saves-before-rebuilding-index ()
  (let* ((root (make-temp-file "org-museum-create-page-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-open-browser-after-export nil)
         (file (expand-file-name "pages/test/created-page.org" root))
         created-buffer)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" root) t)
          (org-museum-index-build t)
          (org-museum-create-page "Created Page" "Test")
          (setq created-buffer (current-buffer))
          (should (equal (buffer-file-name) file))
          (should (file-exists-p file))
          (should-not (buffer-modified-p))
          (should (gethash "created-page"
                           (org-museum-index-pages org-museum--index)))
          (should (= 1 (hash-table-count
                        (org-museum-index-pages org-museum--index)))))
      (when (buffer-live-p created-buffer)
        (with-current-buffer created-buffer
          (set-buffer-modified-p nil))
        (kill-buffer created-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-create-page-rejects-a-separator-only-derived-id ()
  (let* ((root (make-temp-file "org-museum-create-id-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-open-browser-after-export nil)
         (file (expand-file-name "pages/test/-.org" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" root) t)
          (org-museum-index-build t)
          (should-error (org-museum-create-page "!!!" "Test"))
          (should-not (file-exists-p file))
          (should (= 0 (hash-table-count
                        (org-museum-index-pages org-museum--index)))))
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest org-museum-create-page-rejects-a-separator-only-category ()
  (let* ((root (make-temp-file "org-museum-create-category-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-open-browser-after-export nil)
         (file (expand-file-name "pages/valid-page.org" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" root) t)
          (org-museum-index-build t)
          (should-error (org-museum-create-page "Valid Page" "!!!"))
          (should-not (file-exists-p file))
          (should (= 0 (hash-table-count
                        (org-museum-index-pages org-museum--index)))))
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest org-museum-create-page-rejects-reserved-path-components ()
  "Reserved page and category names fail before touching the filesystem."
  (let* ((root (make-temp-file "org-museum-create-path-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-open-browser-after-export nil)
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" root) t)
          (dolist (input '(("CON" "Test") ("Valid" "NUL")))
            (let ((message
                   (condition-case error-data
                       (progn
                         (org-museum-create-page (car input) (cadr input))
                         nil)
                     (error (error-message-string error-data)))))
              (should (string-match-p "保留的.*路径" message))))
          (should (= 0 (hash-table-count
                        (org-museum-index-pages org-museum--index))))
          (should-not (get-file-buffer
                       (expand-file-name "pages/test/con.org" root)))
          (should-not (file-exists-p
                       (expand-file-name "pages/nul/valid.org" root))))
      (delete-directory root t))))

(ert-deftest org-museum-create-page-rolls-back-when-index-persistence-fails ()
  "A failed index write must not leave a page, buffer, or partial index."
  (let* ((root (make-temp-file "org-museum-create-rollback-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-open-browser-after-export nil)
         (file (expand-file-name "pages/test/created-page.org" root))
         (index-path (expand-file-name ".org-museum-index.json" root))
         (pages (make-hash-table :test 'equal))
         (original-index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (org-museum--index original-index))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" root) t)
          ;; A directory at the cache path deterministically makes the final
          ;; atomic rename fail after the page template has been saved.
          (make-directory index-path)
          (should-error (org-museum-create-page "Created Page" "Test"))
          (should-not (file-exists-p file))
          (should-not (get-file-buffer file))
          (should (eq org-museum--index original-index))
          (should (= 0 (hash-table-count
                        (org-museum-index-pages org-museum--index)))))
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-rejects-path-like-id-before-moving-file ()
  (let* ((root (make-temp-file "org-museum-rename-id-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (escaped-file (expand-file-name "pages/escaped.org" root))
         (valid-file (expand-file-name "pages/test/新-id.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (should-error (org-museum-rename-page "original" "../escaped"))
          (should-error (org-museum-rename-page "original" "bad?name"))
          (should (file-exists-p old-file))
          (should-not (file-exists-p escaped-file))
          (with-temp-buffer
            (insert-file-contents old-file)
            (should (re-search-forward
                     "^#\\+WIKI_ID: original$" nil t)))
          (org-museum-rename-page "original" "新-id")
          (should-not (file-exists-p old-file))
          (should (file-exists-p valid-file))
          (should (gethash "新-id"
                           (org-museum-index-pages org-museum--index))))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-rejects-cross-platform-reserved-ids ()
  "Reserved path components fail with Org Museum feedback before any move."
  (let* ((root (make-temp-file "org-museum-rename-path-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (dolist (invalid '("bad?name" "bad:name" "bad*name" "bad|name"
                             "bad<name" "bad>name" "bad\"name" "trailing."
                             "CON" "nul.txt"))
            (let ((message
                   (condition-case error-data
                       (progn
                         (org-museum-rename-page "original" invalid)
                         nil)
                     (error (error-message-string error-data)))))
              (should (string-prefix-p
                       "新 ID 不能为空，且须能安全用作文件路径"
                       message))
              (should (file-exists-p old-file))
              (should (gethash "original" pages)))))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-rolls-back-after-index-persistence-fails ()
  "A late index failure restores the page identity and every rewritten link."
  (let* ((root (make-temp-file "org-museum-rename-rollback-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (ref-file (expand-file-name "pages/test/referrer.org" root))
         (index-path (expand-file-name ".org-museum-index.json" root))
         (old-content
          "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n")
         (ref-content
          "#+TITLE: Referrer\n#+WIKI_ID: referrer\n#+CATEGORY: Test\n[[wiki:original][Original]]\n")
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (pages (make-hash-table :test 'equal))
         (original-index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (org-museum--index original-index))
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file (insert old-content))
          (with-temp-file ref-file (insert ref-content))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (puthash "referrer"
                   (org-museum-test--page
                    "referrer" "Referrer" 1 "Test" nil "published" ref-file)
                   pages)
          (make-directory index-path)
          (should-error (org-museum-rename-page "original" "renamed"))
          (should (file-exists-p old-file))
          (should-not (file-exists-p new-file))
          (should (equal (with-temp-buffer
                           (insert-file-contents old-file)
                           (buffer-string))
                         old-content))
          (should (equal (with-temp-buffer
                           (insert-file-contents ref-file)
                           (buffer-string))
                         ref-content))
          (should (eq org-museum--index original-index))
          (should (gethash "original" pages))
          (should-not (gethash "renamed" pages)))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-keeps-an-open-page-buffer-consistent ()
  "A successful rename keeps the user's existing page buffer on the new file."
  (let* ((root (make-temp-file "org-museum-rename-buffer-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         page-buffer)
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (setq page-buffer (find-file-noselect old-file))
          (org-museum-rename-page "original" "renamed")
          (should (buffer-live-p page-buffer))
          (with-current-buffer page-buffer
            (should (equal (buffer-file-name) new-file))
            (should-not (buffer-modified-p))
            (goto-char (point-min))
            (should (re-search-forward "^#\\+WIKI_ID: renamed$" nil t))))
      (when (buffer-live-p page-buffer)
        (with-current-buffer page-buffer
          (set-buffer-modified-p nil))
        (kill-buffer page-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-refuses-an-unsaved-page-buffer ()
  "Rename must not move a file while its user buffer has unsaved content."
  (let* ((root (make-temp-file "org-museum-rename-unsaved-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         page-buffer)
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (setq page-buffer (find-file-noselect old-file))
          (with-current-buffer page-buffer
            (goto-char (point-max))
            (insert "Unsaved change\n"))
          (let ((message
                 (condition-case error-data
                     (progn
                       (org-museum-rename-page "original" "renamed")
                       nil)
                   (error (error-message-string error-data)))))
            (should (string-prefix-p
                     "请先保存当前笔记，再更名"
                     message)))
          (should (file-exists-p old-file))
          (should-not (file-exists-p new-file))
          (with-current-buffer page-buffer
            (should (equal (buffer-file-name) old-file))
            (should (buffer-modified-p))))
      (when (buffer-live-p page-buffer)
        (with-current-buffer page-buffer
          (set-buffer-modified-p nil))
        (kill-buffer page-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-preserves-an-unindexed-target-file ()
  "A filesystem collision must not delete or overwrite an unrelated page."
  (let* ((root (make-temp-file "org-museum-rename-collision-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (old-content "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n")
         (target-content "unindexed user content\n")
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file (insert old-content))
          (with-temp-file new-file (insert target-content))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (should-error (org-museum-rename-page "original" "renamed"))
          (should (equal (org-museum-test--file-string old-file) old-content))
          (should (equal (org-museum-test--file-string new-file) target-content)))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-rejects-a-visiting-target-buffer-early ()
  "A target path already visited by another buffer fails before Wiki scanning."
  (let* ((root (make-temp-file "org-museum-rename-target-buffer-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         target-buffer
         scan-called)
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (setq target-buffer (find-file-noselect new-file))
          (cl-letf (((symbol-function 'org-museum--rename-link-files)
                     (lambda (_old-id) (setq scan-called t) nil)))
            (should-error (org-museum-rename-page "original" "renamed")))
          (should-not scan-called)
          (should (file-exists-p old-file))
          (should-not (file-exists-p new-file)))
      (when (buffer-live-p target-buffer)
        (with-current-buffer target-buffer (set-buffer-modified-p nil))
        (kill-buffer target-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-refuses-an-unsaved-referrer-buffer ()
  "Rename must not rewrite disk underneath an unsaved referring page buffer."
  (let* ((root (make-temp-file "org-museum-rename-referrer-buffer-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (ref-file (expand-file-name "pages/test/referrer.org" root))
         (ref-content "#+TITLE: Referrer\n#+WIKI_ID: referrer\n[[wiki:original]]\n")
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         ref-buffer)
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (with-temp-file ref-file (insert ref-content))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (setq ref-buffer (find-file-noselect ref-file))
          (with-current-buffer ref-buffer
            (goto-char (point-max))
            (insert "unsaved note\n"))
          (should-error (org-museum-rename-page "original" "renamed"))
          (should (file-exists-p old-file))
          (should-not (file-exists-p new-file))
          (should (equal (org-museum-test--file-string ref-file) ref-content))
          (with-current-buffer ref-buffer
            (should (buffer-modified-p))
            (goto-char (point-min))
            (should (search-forward "unsaved note" nil t))))
      (when (buffer-live-p ref-buffer)
        (with-current-buffer ref-buffer (set-buffer-modified-p nil))
        (kill-buffer ref-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-detects-a-new-unsaved-buffer-link ()
  "A link added only in an unsaved buffer must block rename before disk work."
  (let* ((root (make-temp-file "org-museum-rename-new-buffer-link-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (ref-file (expand-file-name "pages/test/referrer.org" root))
         (disk-content "#+TITLE: Referrer\n#+WIKI_ID: referrer\n")
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         ref-buffer)
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (with-temp-file ref-file (insert disk-content))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (setq ref-buffer (find-file-noselect ref-file))
          (with-current-buffer ref-buffer
            (goto-char (point-max))
            (insert "[[wiki:original]]\n")
            ;; Counterexample: the unsaved link exists outside the user's
            ;; current narrowing and must still be protected.
            (narrow-to-region
             (point-min)
             (save-excursion
               (goto-char (point-min))
               (line-end-position))))
          (should-error (org-museum-rename-page "original" "renamed"))
          (should (file-exists-p old-file))
          (should-not (file-exists-p new-file))
          (should (equal (org-museum-test--file-string ref-file) disk-content))
          (with-current-buffer ref-buffer
            (widen)
            (goto-char (point-min))
            (should (search-forward "[[wiki:original]]" nil t))
            (should (buffer-modified-p))))
      (when (buffer-live-p ref-buffer)
        (with-current-buffer ref-buffer (set-buffer-modified-p nil))
        (kill-buffer ref-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-refreshes-an-open-referrer-buffer ()
  "A clean referring buffer follows the link rewrite and cannot undo it later."
  (let* ((root (make-temp-file "org-museum-rename-clean-referrer-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (ref-file (expand-file-name "pages/test/referrer.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         ref-buffer)
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n"))
          (with-temp-file ref-file
            (insert "#+TITLE: Referrer\n#+WIKI_ID: referrer\n[[wiki:original]]\n"))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (setq ref-buffer (find-file-noselect ref-file))
          (org-museum-rename-page "original" "renamed")
          (with-current-buffer ref-buffer
            (should-not (buffer-modified-p))
            (goto-char (point-min))
            (should (search-forward "[[wiki:renamed]]" nil t))
            (save-buffer))
          (should (string-match-p
                   (regexp-quote "[[wiki:renamed]]")
                   (org-museum-test--file-string ref-file))))
      (when (buffer-live-p ref-buffer)
        (with-current-buffer ref-buffer (set-buffer-modified-p nil))
        (kill-buffer ref-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-rename-page-restores-index-after-a-post-save-failure ()
  "A failure after index persistence restores both the cache and page files."
  (let* ((root (make-temp-file "org-museum-rename-late-rollback-test-" t))
         (old-file (expand-file-name "pages/test/original.org" root))
         (new-file (expand-file-name "pages/test/renamed.org" root))
         (index-file (expand-file-name ".org-museum-index.json" root))
         (old-content "#+TITLE: Original\n#+WIKI_ID: original\n#+CATEGORY: Test\n")
         (cache-content "original cache bytes\n")
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (pages (make-hash-table :test 'equal))
         (original-index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (org-museum--index original-index)
         page-buffer
         (fail-once t)
         (real-set-visited-file-name (symbol-function 'set-visited-file-name)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file (insert old-content))
          (with-temp-file index-file (insert cache-content))
          (puthash "original"
                   (org-museum-test--page
                    "original" "Original" 1 "Test" nil "published" old-file)
                   pages)
          (setq page-buffer (find-file-noselect old-file))
          (cl-letf (((symbol-function 'set-visited-file-name)
                     (lambda (&rest args)
                       (if fail-once
                           (progn
                             (setq fail-once nil)
                             (error "injected post-index failure"))
                         (apply real-set-visited-file-name args)))))
            (should-error (org-museum-rename-page "original" "renamed")))
          (should (equal (org-museum-test--file-string index-file) cache-content))
          (should (equal (org-museum-test--file-string old-file) old-content))
          (should-not (file-exists-p new-file))
          (should (eq org-museum--index original-index))
          (with-current-buffer page-buffer
            (should (equal (buffer-file-name) old-file))))
      (when (buffer-live-p page-buffer)
        (with-current-buffer page-buffer (set-buffer-modified-p nil))
        (kill-buffer page-buffer))
      (delete-directory root t))))

(ert-deftest org-museum-incremental-update-rolls-back-after-late-failure ()
  (let* ((root (make-temp-file "org-museum-index-rollback-test-" t))
         (file (expand-file-name "pages/existing.org" root))
         (org-museum-root-dir root)
         (org-museum-index-file ".index.json")
         (old-page (org-museum-test--page
                    "existing" "Old title" 1 "Test" nil "published" file))
         (new-page (org-museum-test--page
                    "existing" "New title" 2 "Test" nil "published" file))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (save-called nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "#+TITLE: Existing\n"))
          (org-museum--index-register-page org-museum--index old-page)
          (cl-letf (((symbol-function 'org-museum--parse-page-metadata)
                     (lambda (_file) new-page))
                    ((symbol-function 'org-museum--extract-links-from-file)
                     (lambda (&rest _args) (error "late fixture failure")))
                    ((symbol-function 'org-museum--index-save)
                     (lambda (&rest _args) (setq save-called t))))
            (org-museum--index-update-file file))
          (should (eq old-page (gethash "existing" pages)))
          (should (equal (org-museum-page-title (gethash "existing" pages))
                         "Old title"))
          (should-not save-called))
      (delete-directory root t))))

(ert-deftest org-museum-incremental-update-commits-complete-working-copy ()
  (let* ((root (make-temp-file "org-museum-index-commit-test-" t))
         (file (expand-file-name "pages/existing.org" root))
         (target-file (expand-file-name "pages/target.org" root))
         (org-museum-root-dir root)
         (org-museum-index-file ".index.json")
         (old-page (org-museum-test--page
                    "existing" "Old title" 1 "Test" nil "published" file))
         (new-page (org-museum-test--page
                    "existing" "New title" 2 "Test" nil "published" file))
         (target-page (org-museum-test--page
                       "target" "Target" 1 "Test" nil "published" target-file))
         (pages (make-hash-table :test 'equal))
         (original-index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (org-museum--index original-index)
         saved-index)
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "#+TITLE: Existing\n"))
          (with-temp-file target-file (insert "#+TITLE: Target\n"))
          (org-museum--index-register-page org-museum--index old-page)
          (org-museum--index-register-page org-museum--index target-page)
          (cl-letf (((symbol-function 'org-museum--parse-page-metadata)
                     (lambda (_file) new-page))
                    ((symbol-function 'org-museum--extract-links-from-file)
                     (lambda (&rest _args) '("target")))
                    ((symbol-function 'org-museum--index-save)
                     (lambda (index _path) (setq saved-index index))))
            (should (org-museum--index-update-file file)))
          (should-not (eq org-museum--index original-index))
          (should (eq saved-index org-museum--index))
          (should (equal
                   (org-museum-page-title
                    (gethash "existing"
                             (org-museum-index-pages org-museum--index)))
                   "New title"))
          (should (member
                   "existing"
                   (org-museum-page-linked-from
                    (gethash "target"
                             (org-museum-index-pages org-museum--index))))))
      (delete-directory root t))))

(defun org-museum-test--run-unchanged-link-update (old-id new-id)
  "Return index evidence after changing OLD-ID to NEW-ID with one stable link."
  (let* ((root (make-temp-file "org-museum-stable-link-test-" t))
         (file (expand-file-name "pages/source.org" root))
         (target-file (expand-file-name "pages/target.org" root))
         (org-museum-root-dir root)
         (org-museum-index-file ".index.json")
         (old-page (org-museum-test--page
                    old-id "Old" 1 "Test" nil "published" file))
         (new-page (org-museum-test--page
                    new-id "New" 2 "Test" nil "published" file))
         (target-page (org-museum-test--page
                       "target" "Target" 1 "Test" nil "published" target-file))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "#+TITLE: Source\n"))
          (with-temp-file target-file (insert "#+TITLE: Target\n"))
          (setf (org-museum-page-links-to old-page) '("target")
                (org-museum-page-linked-from target-page) (list old-id))
          (org-museum--index-register-page org-museum--index old-page)
          (org-museum--index-register-page org-museum--index target-page)
          (cl-letf (((symbol-function 'org-museum--parse-page-metadata)
                     (lambda (_file) new-page))
                    ((symbol-function 'org-museum--extract-links-from-file)
                     (lambda (&rest _args) '("target")))
                    ((symbol-function 'org-museum--index-save)
                     (lambda (&rest _args) nil)))
            (should (org-museum--index-update-file file)))
          (let* ((updated-pages (org-museum-index-pages org-museum--index))
                 (updated-target (gethash "target" updated-pages)))
            (list :ids (sort (hash-table-keys updated-pages) #'string<)
                  :linked-from
                  (copy-sequence (org-museum-page-linked-from updated-target)))))
      (delete-directory root t))))

(ert-deftest org-museum-incremental-update-keeps-unchanged-link-backreference ()
  (let ((result (org-museum-test--run-unchanged-link-update
                 "source" "source")))
    (should (equal (plist-get result :ids) '("source" "target")))
    (should (equal (plist-get result :linked-from) '("source")))))

(ert-deftest org-museum-incremental-id-change-rewrites-stable-backreference ()
  (let ((result (org-museum-test--run-unchanged-link-update
                 "old-source" "new-source")))
    (should (equal (plist-get result :ids) '("new-source" "target")))
    (should (equal (plist-get result :linked-from) '("new-source")))))

(ert-deftest org-museum-index-save-preserves-old-cache-on-write-failure ()
  (let* ((root (make-temp-file "org-museum-index-atomic-test-" t))
         (path (expand-file-name ".org-museum-index.json" root))
         (page (org-museum-test--page
                "current" "Current" 1 "Test" nil "published"
                (expand-file-name "current.org" root)))
         (pages (make-hash-table :test 'equal))
         (index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (puthash "current" page pages)
          (with-temp-file path (insert "stable-cache"))
          (let ((real-write-region (symbol-function 'write-region)))
            (cl-letf (((symbol-function 'write-region)
                       (lambda (&rest args)
                         (apply real-write-region args)
                         (error "simulated disk failure"))))
              (should-error (org-museum--index-save index path))))
          (with-temp-buffer
            (insert-file-contents path)
            (should (equal (buffer-string) "stable-cache"))))
      (delete-directory root t))))

(ert-deftest org-museum-css-source-prefers-straight-repository-over-roam-copy ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-resource-test-" t)))
         (user-emacs-directory root)
         (repo-dir (expand-file-name "straight/repos/org-museum.el/" root))
         (roam-dir (expand-file-name "org-roam/" root))
         (repo-css (expand-file-name "resources/org-museum.css" repo-dir))
         (roam-css (expand-file-name "resources/org-museum.css" roam-dir))
         (org-museum--plugin-dir nil)
         (load-file-name nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory repo-css) t)
          (make-directory (file-name-directory roam-css) t)
          (with-temp-file repo-css (insert "CURRENT"))
          (with-temp-file roam-css (insert "STALE"))
          (cl-letf (((symbol-function 'locate-library)
                     (lambda (_library) nil)))
            (should (equal (org-museum--css-source-path) repo-css))))
      (delete-directory root t))))

(ert-deftest org-museum-css-source-prefers-repository-over-stale-build-copy ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-build-resource-test-" t)))
         (user-emacs-directory root)
         (repo-dir (expand-file-name "straight/repos/org-museum.el/" root))
         (build-dir (expand-file-name "straight/build/org-museum/" root))
         (repo-css (expand-file-name "resources/org-museum.css" repo-dir))
         (build-css (expand-file-name "resources/org-museum.css" build-dir))
         (build-library (expand-file-name "org-museum.el" build-dir))
         (org-museum--plugin-dir nil)
         (load-file-name nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory repo-css) t)
          (make-directory (file-name-directory build-css) t)
          (with-temp-file repo-css (insert "CURRENT-REPOSITORY"))
          (with-temp-file build-css (insert "STALE-BUILD"))
          (with-temp-file build-library (insert ";; compiled package entry"))
          (cl-letf (((symbol-function 'locate-library)
                     (lambda (_library) build-library)))
            (should (equal (org-museum--css-source-path) repo-css))))
      (delete-directory root t))))

(ert-deftest org-museum-resources-fall-back-to-straight-build-when-repo-is-missing ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-build-fallback-test-" t)))
         (user-emacs-directory root)
         (org-museum-root-dir root)
         (org-museum--plugin-dir
          (expand-file-name "straight/links/org-museum/" root))
         (build-resources
          (expand-file-name "straight/build/org-museum/resources/" root))
         (build-css (expand-file-name "org-museum.css" build-resources))
         (build-d3 (expand-file-name "d3.v7.min.js" build-resources))
         (link-css (expand-file-name "resources/org-museum.css"
                                     org-museum--plugin-dir))
         (link-d3 (expand-file-name "resources/d3.v7.min.js"
                                    org-museum--plugin-dir))
         (missing-css (expand-file-name
                       "straight/repos/org-museum.el/resources/org-museum.css"
                       root))
         (missing-d3 (expand-file-name
                      "straight/repos/org-museum.el/resources/d3.v7.min.js"
                      root))
         (dest (expand-file-name "exports/html/resources/d3.v7.min.js" root))
         (network-called nil))
    (unwind-protect
        (progn
          (make-directory org-museum--plugin-dir t)
          (make-directory build-resources t)
          (make-directory (file-name-directory link-css) t)
          (with-temp-file link-css
            (insert (replace-regexp-in-string "\\\\" "/" missing-css t t)))
          (with-temp-file link-d3
            (insert (replace-regexp-in-string "\\\\" "/" missing-d3 t t)))
          (with-temp-file build-css (insert "/* build css */"))
          (with-temp-file build-d3 (insert "/* build d3 */"))
          (should (equal (org-museum--css-source-path) build-css))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (&rest _args)
                       (setq network-called t)
                       (error "network should not be used"))))
            (should (equal (org-museum--deploy-bundled-resource
                            "resources/d3.v7.min.js" dest "D3.js")
                           dest)))
          (should-not network-called)
          (with-temp-buffer
            (insert-file-contents dest)
            (should (equal (buffer-string) "/* build d3 */"))))
      (delete-directory root t))))

(ert-deftest org-museum-css-source-dereferences-straight-link-placeholder ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-css-link-test-" t)))
         (org-museum--plugin-dir (expand-file-name "straight/links/org-museum/" root))
         (actual (expand-file-name "straight/repos/org-museum.el/resources/org-museum.css"
                                   root))
         (placeholder (expand-file-name "resources/org-museum.css"
                                        org-museum--plugin-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory actual) t)
          (with-temp-file actual (insert "/* actual */"))
          (make-directory (file-name-directory placeholder) t)
          (with-temp-file placeholder
            (insert (replace-regexp-in-string "\\\\" "/" actual t t)))
          (should (equal (org-museum--css-source-path) actual)))
      (delete-directory root t))))

(ert-deftest org-museum-resource-urls-use-stable-content-versions ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-versioned-resource-test-" t)))
         (out-file (expand-file-name "index.html" root))
         (asset (expand-file-name "resources/theme.css" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory asset) t)
          (with-temp-file asset (insert "first"))
          (let ((first (org-museum--versioned-resource-href asset out-file)))
            (should (string-match-p
                     "\\`resources/theme\\.css\\?v=[0-9a-f]\\{12\\}\\'" first))
            (should (equal first
                           (org-museum--versioned-resource-href asset out-file)))
            (with-temp-file asset (insert "second"))
            (should-not
             (equal first
                    (org-museum--versioned-resource-href asset out-file)))))
      (delete-directory root t))))

(ert-deftest org-museum-css-deployment-status-reports-source-output-drift ()
  (let* ((root (make-temp-file "org-museum-css-status-test-" t))
         (source (expand-file-name "source.css" root))
         (output (expand-file-name "output.css" root)))
    (unwind-protect
        (progn
          (with-temp-file source (insert "CURRENT"))
          (with-temp-file output (insert "STALE"))
          (cl-letf (((symbol-function 'org-museum--css-source-path)
                     (lambda () source))
                    ((symbol-function 'org-museum--css-output-path)
                     (lambda () output)))
            (let ((status (org-museum--css-deployment-status)))
              (should (equal (plist-get status :source) source))
              (should (equal (plist-get status :output) output))
              (should (= (length (plist-get status :source-hash)) 64))
              (should (= (length (plist-get status :output-hash)) 64))
              (should-not (plist-get status :in-sync)))))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-caches-highlight-deployment-per-batch ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'org-museum--ensure-hljs-deployed)
               (lambda ()
                 (setq calls (1+ calls))
                 (list :css nil :js nil :lisp-js nil))))
      (let ((org-museum--resource-deployment-cache
             (make-hash-table :test 'eq)))
        (org-museum--hljs-assets)
        (org-museum--hljs-assets)
        (should (= calls 1)))
      (org-museum--hljs-assets)
      (should (= calls 2)))))

(ert-deftest org-museum-highlight-bundle-covers-official-language-set ()
  "The offline browser bundle includes languages outside the common build."
  (let ((bundle (expand-file-name "resources/highlight.min.js"
                                  org-museum-test--repo-root)))
    (should (file-exists-p bundle))
    (with-temp-buffer
      (insert-file-contents-literally bundle)
      ;; The common Highlight.js browser build has only 36 languages.  These
      ;; official grammars deliberately span uncommon language families so a
      ;; renamed common build cannot satisfy the capability by accident.
      (dolist (needle '("brainfuck" "clojure" "fortran"
                        "mathematica" "x86asm"))
        (goto-char (point-min))
        (should (search-forward needle nil t)))
      (should (> (buffer-size) 500000)))))

(ert-deftest org-museum-highlight-normalizes-punctuation-aliases ()
  "Official aliases remain valid when encoded as CSS language classes."
  (dolist (pair '(("x++" . "axapta")
                  ("cmake.in" . "cmake")
                  ("c++" . "cpp")
                  ("h++" . "cpp")
                  ("c#" . "csharp")
                  ("f#" . "fsharp")
                  ("html.hbs" . "handlebars")
                  ("html.handlebars" . "handlebars")
                  ("obj-c++" . "objectivec")
                  ("objective-c++" . "objectivec")
                  ("pf.conf" . "pf")))
    (should (equal (org-museum--hljs-language-for-org (car pair))
                   (cdr pair))))
  (let ((org-museum-code-highlight-method 'hljs))
    (with-temp-buffer
      (insert "<pre class=\"src src-c++\"><code>int main(){}</code></pre>")
      (org-museum--pp-inject-hljs-language-classes)
      (should (string-search "class=\"language-cpp\"" (buffer-string)))
      (should-not (string-search "language-c++" (buffer-string)))))
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (dolist (mapping '("\"c++\":\"cpp\""
                       "\"c#\":\"csharp\""
                       "\"f#\":\"fsharp\""
                       "\"x++\":\"axapta\""))
      (should (string-search mapping script)))))

(ert-deftest org-museum-reading-state-normalizes-corrupt-browser-values ()
  (let ((index-script (org-museum--script-index))
        (reading-script (org-museum--script-reading-state)))
    (should (string-match-p
             (regexp-quote
              "Number.isFinite(parsed)?Math.min(1,Math.max(0,parsed)):0")
             index-script))
    (should (string-match-p
             (regexp-quote "record.progress=progress;record.scrollRatio=progress")
             index-script))
    (should (string-match-p
             (regexp-quote "try{return decodeURIComponent(raw);}catch(_error){return raw;}")
             reading-script))))

(ert-deftest org-museum-reading-state-falls-back-when-v1-index-is-missing ()
  (let ((script (org-museum--script-index)))
    (should (string-match-p
             (regexp-quote "store.indexNames.contains('lastVisitedAt')")
             script))
    (should (string-match-p
             (regexp-quote ":store.openCursor()")
             script))
    (should (string-match-p
             (regexp-quote
              "records.sort(function(a,b){return (b.lastVisitedAt||0)-(a.lastVisitedAt||0);})")
             script))
    (should (string-match-p (regexp-quote "records.slice(0,6)") script))))

(ert-deftest org-museum-exported-html-uses-valid-shared-semantics ()
  (let ((topbar (org-museum--build-topbar "article.html" 'article))
        (sidebar (org-museum--build-sidebar-injection "article.html"))
        (graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" nil)))
    (should (string-match-p "<time class=\"museum-today\"" topbar))
    (should-not (string-match-p
                 "museum-today[^>]*aria-label" topbar))
    (should-not (string-match-p
                 "museum-search-line\" for=" topbar))
    (should-not (string-match-p "<nav id=\"mobile-hud\"" sidebar))
    (should (string-match-p
             "<button type=\"button\" class=\"fx-btn\"" sidebar))
    (should (string-match-p
             "<ul id=\"graph-legend\" aria-label=" graph))
    (should (string-match-p
             "document.createElement('li')" graph))))

(ert-deftest org-museum-mobile-toc-controls-do-not-overlay-reading ()
  (let* ((root (make-temp-file "org-museum-mobile-toc-test-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (page (org-museum-test--page
                "article" "Article title" 1 "Test" nil "draft"))
         (identity (org-museum--article-identity-html
                    page (expand-file-name "exports/html/pages/article.html"
                                           root)))
         (sidebar (org-museum--build-sidebar-injection "article.html"))
         (wrapped
          (let ((org-museum--index nil))
            (with-temp-buffer
              (insert "<html><body><div id=\"content\"><h1 class=\"title\">Article</h1></div></body></html>")
              (org-museum--pp-wrap-content-div "article.html" "article.org")
              (buffer-string))))
         (css (with-temp-buffer
                (insert-file-contents
                 (expand-file-name "resources/org-museum.css"
                                   org-museum-test--repo-root))
                (buffer-string))))
    (unwind-protect
        (progn
          (should (string-match-p "museum-identity-toc" identity))
          (should (string-match-p "data-toc-toggle" identity))
          (should (string-match-p "museum-article-toc-trigger" wrapped))
          (should-not (string-match-p "id=\"mobile-hud\"" sidebar))
          (should (string-match-p "museum-identity-toc" css))
          (should-not (string-match-p "#mobile-hud" css)))
      (delete-directory root t))))

(ert-deftest org-museum-postprocess-repairs-org-tag-entities-and-table-landmarks ()
  (with-temp-buffer
    (insert "<h2>Tagged&nbsp;&nbsp;&nbsp<span class=\"tag\">P1</span></h2>")
    (org-museum--pp-fix-exported-entities)
    (should (equal (buffer-string)
                   "<h2>Tagged&nbsp;&nbsp;&nbsp;<span class=\"tag\">P1</span></h2>")))
  (with-temp-buffer
    (insert "<table><tr><td>A</td></tr></table>\n"
            "<table><tr><td>B</td></tr></table>")
    (org-museum--pp-wrap-tables)
    (let ((html (buffer-string)))
      (should (string-match-p
               "<section class=\"museum-table-scroll\"[^>]*aria-label=\"[^\"]* 1\""
               html))
      (should (string-match-p
               "<section class=\"museum-table-scroll\"[^>]*aria-label=\"[^\"]* 2\""
               html))
      (should (= (org-museum-test--count-occurrences "</section>" html) 2)))))

(ert-deftest org-museum-postprocess-targets-the-real-body-tag ()
  "Metadata and chrome must not be injected into an exporter comment."
  (let* ((page (org-museum-test--page
                "article" "Article" 1 "Sql" '("duckdb") "draft"
                "c:/fixture/article.org"))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (puthash (org-museum-page-id page) page pages)
    (with-temp-buffer
      (insert "<html><head><!-- generated <body data-decoy=\"yes\"> at 11:20 --></head>"
              "<body><div id=\"content\"></div></body></html>")
      (cl-letf (((symbol-function 'file-equal-p)
                 (lambda (a b) (equal a b)))
                ((symbol-function 'org-museum--format-page-date)
                 (lambda (_page)
                   ;; Reproduce the match-data clobbering that used to move
                   ;; the replacement into Org's export timestamp comment.
                   (string-match "20" "11:20")
                   "2026-08-21"))
                ((symbol-function 'org-museum--hljs-css-src)
                 (lambda (_out-file) "resources/highlight.css"))
                ((symbol-function 'org-museum--hljs-js-src)
                 (lambda (_out-file) "resources/highlight.js"))
                ((symbol-function 'org-museum--hljs-lisp-js-src)
                 (lambda (_out-file) "resources/highlight-lisp.js"))
                ((symbol-function 'org-museum--build-topbar)
                 (lambda (&rest _args) "<header id=\"real-topbar\"></header>"))
                ((symbol-function 'org-museum--build-sidebar-injection)
                 (lambda (&rest _args) "")))
        (org-museum--pp-inject-page-attributes
         "c:/fixture/article.org" "article.html")
        (org-museum--pp-inject-sidebars-and-scripts "article.html"))
      (let ((html (buffer-string)))
        (should (string-search
                 "<!-- generated <body data-decoy=\"yes\"> at 11:20 -->" html))
        (should (string-search
                 "<body class=\"org-museum-page\"" html))
        (should (string-search
                 "data-hljs-js=\"resources/highlight.js\"" html))
        (should (< (string-match "</head>" html)
                   (string-match "<header id=\"real-topbar\"" html)))))))

(ert-deftest org-museum-postprocess-preserves-plain-result-lines ()
  "Plain #+begin_results output remains readable line by line."
  (with-temp-buffer
    (insert "<div class=\"results\" id=\"result-1\">\n"
            "<p>\nid,asset,amount\n1,BTC,1000\n2,ETH,2000\n</p>\n"
            "</div>\n"
            "<div class=\"results\"><table><tr><td>rich</td></tr></table></div>")
    (org-museum--pp-normalize-plain-results)
    (let ((html (buffer-string)))
      (should (string-search
               (concat "<pre class=\"org-museum-results\" tabindex=\"0\" "
                       "aria-label=\"代码运行结果\"><code>"
                       "id,asset,amount\n1,BTC,1000\n2,ETH,2000"
                       "</code></pre>")
               html))
      (should (string-search
               "<div class=\"results\"><table><tr><td>rich</td>" html))))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward ".org-museum-results" nil t))))

(ert-deftest org-museum-css-deployment-prefers-content-over-mtime ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-css-content-test-" t)))
         (src (expand-file-name "source.css" root))
         (dst (expand-file-name "export/resources/theme.css" root)))
    (unwind-protect
        (progn
          (with-temp-file src (insert "current"))
          (make-directory (file-name-directory dst) t)
          (with-temp-file dst (insert "stale"))
          (set-file-times dst (time-add (current-time) 3600))
          (cl-letf (((symbol-function 'org-museum--css-source-path)
                     (lambda () src))
                    ((symbol-function 'org-museum--css-output-path)
                     (lambda () dst)))
            (org-museum--ensure-css-deployed))
          (with-temp-buffer
            (insert-file-contents dst)
            (should (equal (buffer-string) "current"))))
      (delete-directory root t))))

(ert-deftest org-museum-bundled-resource-is-copied-before-network-fetch ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-bundled-resource-test-" t)))
         (org-museum-root-dir root)
         (org-museum--plugin-dir (expand-file-name "plugin/" root))
         (bundled (expand-file-name "resources/d3.v7.min.js"
                                    org-museum--plugin-dir))
         (dest (expand-file-name "exports/html/resources/d3.v7.min.js" root))
         (network-called nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory bundled) t)
          (with-temp-file bundled (insert "/* bundled */"))
          (make-directory (file-name-directory dest) t)
          (with-temp-file dest (insert "/* stale */"))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (&rest _args)
                       (setq network-called t)
                       (error "network should not be used"))))
            (should
             (equal (org-museum--deploy-bundled-resource
                     "resources/d3.v7.min.js" dest "D3.js")
                    dest)))
          (should-not network-called)
          (with-temp-buffer
            (insert-file-contents dest)
            (should (equal (buffer-string) "/* bundled */"))))
      (delete-directory root t))))

(ert-deftest org-museum-bundled-resource-dereferences-straight-link-placeholders ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-link-resource-test-" t)))
         (org-museum-root-dir root)
         (org-museum--plugin-dir (expand-file-name "straight/links/org-museum/" root))
         (actual (expand-file-name "straight/repos/org-museum.el/resources/highlight.min.js"
                                   root))
         (placeholder (expand-file-name "resources/highlight.min.js"
                                        org-museum--plugin-dir))
         (dest (expand-file-name "exports/html/resources/highlight.min.js" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory actual) t)
          (with-temp-file actual (insert "/* real highlight */"))
          (make-directory (file-name-directory placeholder) t)
          (with-temp-file placeholder
            (insert (replace-regexp-in-string "\\\\" "/" actual t t)))
          (should (equal (org-museum--deploy-bundled-resource
                          "resources/highlight.min.js"
                          dest "Highlight.js")
                         dest))
          (with-temp-buffer
            (insert-file-contents dest)
            (should (equal (buffer-string) "/* real highlight */"))))
      (delete-directory root t))))

(ert-deftest org-museum-page-metadata-is-injected ()
  (let* ((page (org-museum-test--page
                "page-中文" "标题 & 特殊" 100 "Emacs" '("org" "中文")))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (setf (org-museum-page-path page) "c:/fixture/page.org")
    (puthash (org-museum-page-id page) page pages)
    (with-temp-buffer
      (insert "<html><body><div id=\"content\"></div></body></html>")
      (cl-letf (((symbol-function 'file-equal-p)
                 (lambda (a b) (equal a b))))
        (org-museum--pp-inject-page-attributes "c:/fixture/page.org"))
      (should (string-match-p "data-page-id=\"page-中文\"" (buffer-string)))
      (should (string-match-p "data-page-title=\"标题 &amp; 特殊\"" (buffer-string)))
      (should (string-match-p "data-page-category=\"Emacs\"" (buffer-string)))
      (should (string-match-p "data-page-tags=\"org,中文\"" (buffer-string))))))

(ert-deftest org-museum-article-heading-anchor-clears-sticky-identity ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward
             ".article-container h2,\n.article-container h3,\n.article-container h4" nil t))
    (should (search-forward "scroll-margin-top: 48px" nil t))))

(ert-deftest org-museum-article-section-state-is-shared-by-toc-identity-and-reading-history ()
  (let ((ui-script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) nil))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) nil))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) nil)))
           (org-museum--script-ui-core "article.html")))
        (shell-script (org-museum--script-shell))
        (reading-script (org-museum--script-reading-state)))
    (should (string-match-p "window\.orgMuseumActiveHeading" ui-script))
    (should (string-match-p "museum:active-heading" ui-script))
    (should (string-match-p "source:source" ui-script))
    (should (string-match-p "museum:active-heading" shell-script))
    (should (string-match-p "museum:active-heading" reading-script))
    (should-not (string-match-p "function updateActiveHeading" reading-script))))

(ert-deftest org-museum-article-anchor-survives-responsive-reflow-until-user-scroll ()
  "A layout-only scroll event must not replace the URL-selected section."
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) nil))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) nil))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) nil)))
           (org-museum--script-ui-core "article.html"))))
    (should (string-search "anchorLocked" script))
    (should (string-search "function unlockAnchor" script))
    (should (string-search "'wheel'" script))
    (should (string-search "'touchstart'" script))
    (should (string-search "'pointerdown'" script))
    (should (string-search "'j','k','n','p'" script))
    (should (string-search "anchorLocked||Date.now()<preferredUntil" script))))

(ert-deftest org-museum-reading-state-recovers-stale-heading-by-title ()
  (let ((script (org-museum--script-reading-state)))
    (should (string-match-p "function headingByTitle" script))
    (should (string-match-p "saved\.lastHeadingTitle" script))
    (should (string-match-p "matches\.length===1" script))
    (should (string-match-p "saved\.lastHeadingId=target\.id" script))
    (should (string-match-p
             "objectStore('readingState')\.put(saved)" script))))

(ert-deftest org-museum-reading-state-saves-on-hide-and-cleans-up-timers ()
  (let ((script (org-museum--script-reading-state)))
    (should (string-match-p "saveInterval=null" script))
    (should (string-search "document.visibilityState==='hidden'" script))
    (should (string-search "clearInterval(saveInterval)" script))
    (should (string-search "window.addEventListener('pageshow'" script))
    (should (string-search "if(restoreStarted)return" script))
    (should (string-search "function startPeriodicSave" script))))

(ert-deftest org-museum-article-width-is-configurable-and-exported ()
  (should (= org-museum-article-max-width 1320))
  (let ((org-museum-article-max-width 912)
        (org-museum--index nil))
    (with-temp-buffer
      (insert "<html><body><div id=\"content\"><h1>Article</h1></div></body></html>")
      (should (org-museum--pp-wrap-content-div "article.html" "article.org"))
      (goto-char (point-min))
      (should (search-forward
               "style=\"--museum-article-max-width: 912px\"" nil t))))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "var(--museum-article-max-width, 1320px)" nil t))))

(ert-deftest org-museum-article-wrapper-survives-metadata-match-data ()
  "Metadata parsing must not invalidate the content replacement bounds."
  (with-temp-buffer
    (insert "<html><body><div id=\"content\"><h1>Article</h1></div></body></html>")
    (cl-letf (((symbol-function 'org-museum--page-for-file)
               (lambda (_file)
                 (org-museum-test--page "id" "Title" 1 "Topic")))
              ((symbol-function 'org-museum--article-meta-html)
               (lambda (&rest _args)
                 (string-match "ab" "ab")
                 "<aside class=\"museum-article-meta\"></aside>"))
              ((symbol-function 'org-museum--article-identity-html)
               (lambda (&rest _args) "")))
      (should (org-museum--pp-wrap-content-div "article.html" "article.org"))
      (goto-char (point-min))
      (should (search-forward "<main id=\"main-scroll\">" nil t))
      (should (search-forward "<h1>Article</h1>" nil t)))))

(ert-deftest org-museum-background-effects-are-opt-in-and-motion-safe ()
  (should org-museum-background-effects-enabled)
  (let ((org-museum-background-effects-enabled nil))
    (should (equal (org-museum--sidebar-fx-controls) ""))
    (should (equal (org-museum--script-effects) "")))
  (let* ((org-museum-background-effects-enabled t)
         (controls (org-museum--sidebar-fx-controls))
         (script (org-museum--script-effects)))
    (should (string-match-p "<details class=\"sidebar-fx-controls\"" controls))
    (should (string-match-p "org-museum-bg-fx-v2" script))
    (should-not (string-match-p "org-museum-bg-fx'" script))
    (should (string-match-p "prefers-reduced-motion: reduce" script))
    (should (string-match-p "zen-mode" script))
    (should (string-match-p "MutationObserver" script))
    (should (string-match-p "removeEventListener" script))
    (should (string-match-p "getPropertyValue('--font-code')" script))
    (should-not (string-match-p "px monospace" script))
    (should (string-match-p "visibilitychange" script))
    (should (string-match-p "pagehide" script))))

(ert-deftest org-museum-long-code-blocks-have-a-real-collapse-state ()
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (should (string-match-p
             (regexp-quote "replace(/\\r?\\n$/,'')") script))
    (should (string-match-p
             (regexp-quote "code.getBoundingClientRect().height>320") script))
    (should (string-match-p "if(isLong)" script))
    (should (string-match-p "org-museum-code-collapsed" script))
    (should (string-match-p "aria-expanded" script)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward ".org-museum-code-collapsed" nil t))
    (should (search-forward "max-height: 320px" nil t))
    (should (search-forward ".org-museum-code-expanded" nil t))))

(ert-deftest org-museum-scrollable-code-is-keyboard-focusable ()
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (should (string-match-p
             (regexp-quote "pre.scrollWidth>pre.clientWidth+1") script))
    (should (string-match-p (regexp-quote "pre.tabIndex=0") script))
    (should (string-match-p
             (regexp-quote "scheduleCodeScrollAccess();") script))))

(ert-deftest org-museum-cjk-spacing-preserves-code-and-literal-content ()
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (should (string-match-p "parentElement\\.closest" script))
    (should (string-match-p
             (regexp-quote
              "pre,code,kbd,samp,script,style,textarea,[contenteditable]")
             script))))

(ert-deftest org-museum-search-and-tooltip-render-untrusted-text-safely ()
  (let ((ui-script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html")))
        (search-script (org-museum--script-sidebar-search)))
    (should-not (string-match-p
                 (regexp-quote "tt.innerHTML='<strong>'+l.textContent") ui-script))
    (should (string-match-p "tt.replaceChildren" ui-script))
    (should-not (string-match-p
                 (regexp-quote "a.innerHTML = pre +") search-script))
    (should (string-match-p "a.replaceChildren" search-script))))

(ert-deftest org-museum-pages-have-keyboard-skip-navigation ()
  (let* ((root (make-temp-file "org-museum-a11y-test-" t))
         (org-museum-root-dir root)
         (topbar (org-museum--build-topbar
                  (expand-file-name "exports/html/index.html" root) 'home)))
    (should (string-match-p
             (regexp-quote "class=\"museum-skip-link\" href=\"#main-content\"")
             topbar)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward ".museum-skip-link:focus" nil t))))

(ert-deftest org-museum-lightbox-is-keyboard-accessible ()
  (let ((script
         (cl-letf (((symbol-function 'org-museum--hljs-lisp-js-src)
                    (lambda (_out-file) "resources/highlight-lisp.min.js"))
                   ((symbol-function 'org-museum--hljs-css-src)
                    (lambda (_out-file) "resources/highlight.monokai.min.css"))
                   ((symbol-function 'org-museum--hljs-js-src)
                    (lambda (_out-file) "resources/highlight.min.js")))
           (org-museum--script-ui-core "article.html"))))
    (should (string-match-p "aria-modal" script))
    (should (string-match-p "event.key==='Escape'" script))
    (should (string-match-p "event.key==='Tab'" script))
    (should (string-match-p "lastFocus.focus" script))
    (should (string-match-p "oli.alt=img.alt" script)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "#image-lightbox-overlay.visible" nil t))))

(ert-deftest org-museum-mobile-primary-controls-have-touch-sized-hit-areas ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "--museum-touch-target: 44px" nil t))
    (should (search-forward "min-height: var(--museum-touch-target)" nil t))
    (should (search-forward ".code-copy-btn" nil t))
    (should (search-forward "#graph-category-filters button" nil t))
    (should (search-forward ".museum-status-filters button" nil t))
    (should (search-forward ".museum-filter-summary button" nil t))
    (should (search-forward ".topic-filter" nil t))))

(ert-deftest org-museum-code-and-graph-detail-actions-have-usable-hit-areas ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (string-match-p
             "\\.code-copy-btn[[:space:]\n]*{[^}]*min-width: 44px;[^}]*min-height: 28px;"
             (buffer-string)))
    (should (string-match-p
             "#graph-neighbours button[[:space:]\n]*{[^}]*min-height: 28px;"
             (buffer-string)))
    (should (string-match-p
             "#graph-neighbours button,[[:space:]\n]*\\.graph-inspector-actions a,[[:space:]\n]*\\.graph-inspector-actions button,[[:space:]\n]*#btn-clear-selection[[:space:]\n]*{[^}]*min-height: 44px;"
             (buffer-string)))
    (should (string-match-p
             "#btn-clear-selection[[:space:]\n]*{[^}]*min-width: 44px;"
             (buffer-string)))))

(ert-deftest org-museum-light-theme-shell-and-mobile-reading-targets-stay-usable ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (let ((css (buffer-string)))
      (should (string-match-p
               "\\.museum-topbar :where(\\.museum-topbar-link:not(\\.museum-wordmark),[[:space:]\n]*\\.museum-theme-toggle, \\.museum-drawer-toggle)[[:space:]\n]*{[^}]*color: var(--museum-shell-muted);"
               css))
      (should (string-match-p
               "#org-museum-sidebar \\.sidebar-nav-btn,[[:space:]\n]*#org-museum-sidebar \\.sidebar-category a,[[:space:]\n]*\\.museum-index-entry h3 a[[:space:]\n]*{[^}]*min-height: 44px;"
               css))
      (should (string-match-p
               "#org-museum-sidebar \\.sidebar-category a,[[:space:]\n]*#org-museum-sidebar input[[:space:]\n]*{[^}]*color: var(--museum-shell-muted);"
               css))
      (should (string-match-p
               "#org-museum-sidebar \\.sidebar-cat-label[[:space:]\n]*{[^}]*color: var(--museum-shell-accent);"
               css))
      (should (string-match-p
               "#org-museum-right-sidebar a[[:space:]\n]*{[^}]*min-height: 44px;"
               css))
      (should (string-match-p
               "\\.museum-filter-summary button[[:space:]\n]*{[^}]*min-width: 44px;"
               css)))))

(ert-deftest org-museum-closed-drawers-are-not-keyboard-focusable ()
  (let ((script (org-museum--script-shell)))
    (should (string-match-p
             (regexp-quote "panel.inert=!available") script))
    (should (string-match-p
             (regexp-quote "setPanelAvailable(drawer,false)") script))
    (should (string-match-p
             (regexp-quote "setPanelAvailable(toc,!tocDrawerMedia.matches)")
             script))))

(ert-deftest org-museum-offline-assets-never-fall-back-to-cdns ()
  (cl-letf (((symbol-function 'org-museum--ensure-hljs-deployed)
             (lambda () (list :css nil :js nil :lisp-js nil)))
            ((symbol-function 'org-museum--ensure-d3-deployed)
             (lambda () nil)))
    (should-not (org-museum--hljs-css-src "article.html"))
    (should-not (org-museum--hljs-js-src "article.html"))
    (should-not (org-museum--hljs-lisp-js-src "article.html"))
    (should-not (org-museum--d3-js-src "graph.html"))
    (let ((script (org-museum--script-ui-core "article.html"))
          (graph (org-museum--build-graph-html
                  "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                  "resources/org-museum.css" nil)))
      (should-not (string-match-p "https?://" script))
      (should-not (string-match-p "https?://" graph)))))

(ert-deftest org-museum-graph-emits-one-valid-local-d3-script-tag ()
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-match-p
             (regexp-quote "<script src=\"resources/d3.v7.min.js\"></script>")
             graph))
    (should-not (string-match-p "src=\"<script" graph))))

(ert-deftest org-museum-graph-keeps-mobile-labels-and-interactions-in-bounds ()
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-match-p "graph-node-hit-target" graph))
    (should (string-search "org-museum-graph-network.js" graph)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum-graph-network.js" org-museum-test--repo-root))
    (let ((source (buffer-string)))
      (should (string-search "graph-node-hit-target').attr('r', 25)" source))
      (should (string-search "window.innerWidth <= 600 ? 9 : 16" source))
      (should (string-search "node.name + '，' + node.degree" source))
      (should (string-search "event.key === ' '" source))
      (should (string-search "d3.drag().clickDistance(4)" source))
      (should (string-search "if (window.ResizeObserver)" source))))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    ;; [UI-01] Short desktop viewports keep every rail control reachable.
    (should (re-search-forward
             "\\.museum-graph-rail[[:space:]\n]*{[^}]*overflow-y: auto;"
             nil t))
    ;; [UI-02] Reduced-motion disabling has a visible non-interactive state.
    (should (re-search-forward
             "\\.graph-view-controls button:disabled[[:space:]\n]*{[^}]*cursor: not-allowed;"
             nil t))
    ;; [UI-04] Enabled graph controls expose the shared primary hover/focus cue.
    (should (re-search-forward
             "\\.graph-view-controls button:not(:disabled):hover,[[:space:]\n]*\\.graph-view-controls button:not(:disabled):focus-visible[[:space:]\n]*{[^}]*color: var(--museum-accent);"
             nil t))
    ;; [UI-03] Keyboard focus is drawn on the visible graph-node dot.
    (should (re-search-forward
             "\\.graph-nodes g:focus-visible \\.graph-node-dot"
             nil t))
    (goto-char (point-min))
    (should (re-search-forward
             "\\.graph-page \\.graph-view-controls button[^{]*{[^}]*min-height: 44px;"
             nil t))
    (goto-char (point-min))
    (should (re-search-forward
             "\\.graph-isolated-list \\.graph-isolated-actions button[[:space:]\n]*{[^}]*min-height: 44px;"
             nil t))
    (goto-char (point-min))
    (should (re-search-forward
             "\\.graph-links path\\.is-dimmed[[:space:]\n]*{[^}]*opacity: 0\\.14;"
             nil t))
    (goto-char (point-min))
    (should (re-search-forward
             "\\.graph-link-labels text\\.is-dimmed[[:space:]\n]*{[^}]*opacity: 0\\.14;"
             nil t))))

(ert-deftest org-museum-graph-reflows-after-viewport-changes ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum-graph-network.js" org-museum-test--repo-root))
    (let ((source (buffer-string)))
      (should (string-search "svg.attr('viewBox', '0 0 ' + w + ' ' + h)" source))
      (should (string-search "function resizeGraph()" source))
      (should (string-search "resize.observe(canvas)" source))
      (should (string-search "window.addEventListener('resize', resizeGraph)" source)))))

(ert-deftest org-museum-mobile-timeline-actions-have-touch-sized-hit-areas ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (string-match-p
             "\\.timeline-filter-close,[[:space:]\n]*#timeline-isolated-list button,[[:space:]\n]*\\.timeline-mobile-node[[:space:]\n]*{[^}]*min-height: 44px;"
             (buffer-string)))))

(ert-deftest org-museum-graph-search-and-selection-share-visible-state ()
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (dolist (id '("graph-match-status" "btn-clear-selection" "graph-canvas"))
      (should (string-search (concat "id=\"" id "\"") graph))))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum-graph-network.js" org-museum-test--repo-root))
    (let ((source (buffer-string)))
      (should (string-search "var selectedNodeId = params.get('focus')" source))
      (should (string-search "var query = (params.get('q')" source))
      (should (string-search "var category = params.get('category')" source))
      (should (string-search "function visibleNodes()" source))
      (should (string-search "function showNode(node, pushHistory)" source))
      (should (string-search "if (selectedNodeId) showNode(nodeById(selectedNodeId)" source)))))

(ert-deftest org-museum-css-themes-scroll-regions-and-print-output ()
  "Scrollable UI stays Monokai on screen and articles become paper-friendly."
  (let ((css (with-temp-buffer
               (insert-file-contents
                (expand-file-name "resources/org-museum.css"
                                  org-museum-test--repo-root))
               (buffer-string))))
    (should (string-match-p "--scrollbar-track:" css))
    (should (string-match-p
             "scrollbar-color: var(--scrollbar-thumb) var(--scrollbar-track)"
             css))
    (should (string-match-p "graph-node-hit-target" css))
    (should (string-match-p "pointer-events: all" css))
    (let ((print-pos (string-match "@media print" css)))
      (should print-pos)
      (should (string-match "#org-museum-sidebar" css print-pos))
      (should (string-match "#museum-drawer-backdrop" css print-pos))
      (should (string-match "\\.museum-article-toc-trigger" css print-pos)))
    (should (string-match-p "\\.museum-topbar" css))
    (should (string-match-p ":root\\[data-theme=\"light\"\\]" css))
    (should (string-match-p "--topbar-bg:" css))
    (should (string-match-p "\\.museum-theme-toggle" css))
    (should-not (string-match-p "mobile-drawer-overlay" css))
    (should (string-match-p "\\.reading-hud" css))
    (should-not (string-match-p "#mobile-hud" css))
    (should (string-match-p "\\.museum-identity-toc" css))
    (should (string-match-p "\\.museum-article-toc-trigger" css))
    (should (string-match-p "break-inside: avoid" css))
    (should (string-match-p "background: #fff" css))))

(ert-deftest org-museum-org-html-has-complete-monokai-semantic-colors ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (dolist (selector '(".article-container strong"
                        ".article-container em"
                        ".article-container li::marker"
                        ".article-container code:not(.org-museum-code)"
                        ".article-container .todo"
                        ".article-container .timestamp"
                        ".org-keyword"
                        ".org-string"
                        ".org-function-name"
                        ".org-type"
                        ".org-constant"
                        ".org-comment"
                        ".hljs-keyword"
                        ".hljs-string"
                        ".hljs-number"))
      (goto-char (point-min))
      (should (search-forward selector nil t)))
    (goto-char (point-min))
    (should (search-forward "--mono-pink: #ff4f8b" nil t)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/highlight.monokai.min.css"
                       org-museum-test--repo-root))
    (should (search-forward "color:#ff4f8b" nil t))
    (should (search-forward "color:#95907c" nil t))
    (goto-char (point-min))
    (should (search-forward "pre code.hljs{display:block;overflow:visible;padding:0}" nil t))
    (should-not (search-forward "color:#f92672" nil t))))

(ert-deftest org-museum-index-data-and-empty-state-are-stable ()
  (let* ((root (make-temp-file "org-museum-index-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/index.html" root))
         (page (org-museum-test--page
                "alpha" "中文 <Alpha>" 42 "Emacs" '("test")))
         (cats `(("Emacs" . (,page))))
         (html (org-museum--build-index-html cats "graph.html" out-file))
         (empty (org-museum--build-index-html nil "graph.html" out-file)))
    (unwind-protect
        (progn
          (should (string-match-p "org-museum-index-data" html))
          (should (string-match-p "\"pageId\":\"alpha\"" html))
          (should (string-match-p "\\\\u003cAlpha\\\\u003e" html))
          (should (string-match-p "搜索标题、章节、标签或主题" html))
          (should (string-match-p "全部笔记 · 按更新时间" html))
          (should (string-match-p "rel=\\\"icon\\\" href=\\\"data:,\\\"" html))
          (should (string-match-p "索引为空" empty))
          (should (string-match-p "\"pages\":\\[\\]" empty)))
      (delete-directory root t))))

(ert-deftest org-museum-dashboard-source-changes-rebuild-facets ()
  "Adding, editing, and deleting isolated Org notes updates the browser data."
  (let* ((root (make-temp-file "org-museum-dashboard-changes-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum--index nil)
         (pages (expand-file-name "pages" root))
         (alpha (expand-file-name "alpha.org" pages))
         (beta (expand-file-name "beta.org" pages)))
    (unwind-protect
        (progn
          (make-directory pages t)
          (with-temp-file alpha
            (insert "#+TITLE: DuckDB Alpha\n#+WIKI_ID: alpha\n"
                    "#+CATEGORY: Sql\n#+FILETAGS: :duckdb:\n"
                    "#+WIKI_STATUS: draft\n* Notes\n"))
          (org-museum-index-build t)
          (should (= 1 (hash-table-count
                        (org-museum-index-pages org-museum--index))))
          (should (gethash "duckdb" (org-museum-index-tags org-museum--index)))
          (with-temp-file beta
            (insert "#+TITLE: PostgreSQL Beta\n#+WIKI_ID: beta\n"
                    "#+CATEGORY: Data\n#+FILETAGS: :PostgreSQL:\n"
                    "#+WIKI_STATUS: published\n* Notes\n"))
          (org-museum-index-build t)
          (should (= 2 (hash-table-count
                        (org-museum-index-pages org-museum--index))))
          (should (gethash "PostgreSQL" (org-museum-index-tags org-museum--index)))
          (with-temp-file alpha
            (insert "#+TITLE: Ontology Alpha\n#+WIKI_ID: alpha\n"
                    "#+CATEGORY: Ontology\n#+FILETAGS: :concept:\n"
                    "#+WIKI_STATUS: published\n* Revised notes\n"))
          (org-museum-index-build t)
          (let ((changed (gethash "alpha"
                                  (org-museum-index-pages org-museum--index))))
            (should (equal (org-museum-page-title changed) "Ontology Alpha"))
            (should (equal (org-museum-page-category changed) "Ontology"))
            (should (equal (org-museum-page-tags changed) '("concept"))))
          (should-not (gethash "duckdb" (org-museum-index-tags org-museum--index)))
          (delete-file beta)
          (org-museum-index-build t)
          (should (= 1 (hash-table-count
                        (org-museum-index-pages org-museum--index))))
          (should-not (gethash "PostgreSQL" (org-museum-index-tags org-museum--index)))
          (should-not (gethash "Data" (org-museum-index-categories org-museum--index))))
      (delete-directory root t))))

(ert-deftest org-museum-index-filters-share-one-url-backed-state ()
  (let* ((root (make-temp-file "org-museum-index-filter-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/index.html" root))
         (page (org-museum-test--page
                "alpha" "Alpha" 42 "Sql" '("database") "draft"))
         (html (org-museum--build-index-html
                `(("Sql" . (,page))) "graph.html" out-file))
         (script (org-museum--script-index)))
    (unwind-protect
        (progn
          (should (string-match-p "data-index-reset" html))
          (should (string-match-p "data-clear-index-filters" html))
          (should (string-match-p "id=\"index-filter-summary\"" html))
          (should (string-match-p
                   "<button type=\"button\" class=\"museum-entry-category\""
                   html))
          (should (string-match-p "aria-live=\"polite\"" html))
          (dolist (contract '("sourceData:sourceData"
                              "filterSchema:buildSchema(sourceData)"
                              "filteredData:[]"
                              "aggregations:{metrics:"
                              "function matches(page,except)"
                              "function optionCounts(key)"
                              "history.pushState"
                              "addEventListener('popstate'"
                              "key==='tags'?'tag':key"
                              "params.get(parameter)"
                              "setAttribute('aria-pressed'"))
            (should (string-search contract script))))
      (delete-directory root t))))

(ert-deftest org-museum-index-includes-drafts-headings-and-status-filters ()
  (let* ((root (make-temp-file "org-museum-index-status-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (org-museum-category-label-alist '(("Sql" . "SQL")))
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (out-file (expand-file-name "exports/html/index.html" root))
         (published-path (expand-file-name "published.org" root))
         (draft-path (expand-file-name "draft.org" root))
         (published (org-museum-test--page
                     "published" "DuckDB 入门" 42 "Sql" '("database")
                     "published" published-path))
         (draft (org-museum-test--page
                 "draft" "DuckDB 草稿" 41 "Sql" '("notes")
                 "draft" draft-path)))
    (unwind-protect
        (progn
          (with-temp-file published-path
            (insert "#+TITLE: DuckDB 入门\n* 安装\n** Windows 配置\n"))
          (with-temp-file draft-path
            (insert "#+TITLE: DuckDB 草稿\n* 查询优化\n"))
          (let ((html (org-museum--build-index-html
                       `(("Sql" . (,published ,draft))) "graph.html" out-file)))
            (should (string-match-p "\"schemaVersion\":2" html))
            (should (string-match-p "\"status\":\"draft\"" html))
            (should (string-match-p "\"title\":\"Windows 配置\"" html))
            (should (string-match-p "\"level\":2" html))
            (should (string-match-p "data-status=\"draft\"" html))
            (should (string-match-p "museum-status-badge" html))
            (should (string-match-p "id=\"index-dynamic-filters\"" html))
            (should (string-search "dimensionLabel(key)" (org-museum--script-index)))
            (should (string-match-p ">SQL<" html))
            (should (string-match-p "2 篇索引" html))))
      (delete-directory root t))))

(ert-deftest org-museum-description-cache-and-health-are-backward-compatible ()
  (let* ((root (make-temp-file "org-museum-description-test-" t))
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (described-file (expand-file-name "described.org" root))
         (missing-file (expand-file-name "missing-description.org" root))
         (pages (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (with-temp-file described-file
            (insert "#+TITLE: 有描述\n#+WIKI_ID: described\n"
                    "#+DESCRIPTION: 一段摘要\n#+WIKI_STATUS: published\n"))
          (with-temp-file missing-file
            (insert "#+TITLE: 无描述\n#+WIKI_ID: missing-description\n"
                    "#+WIKI_STATUS: draft\n"))
          (let ((described (org-museum--parse-page-metadata described-file))
                (missing (org-museum--parse-page-metadata missing-file)))
            (should (equal (org-museum-page-description described) "一段摘要"))
            (puthash "described" described pages)
            (puthash "missing-description" missing pages)
            (let ((health (org-museum--index-health-report pages)))
              (should (= (length (plist-get health :isolated)) 2))
              (should (equal (plist-get health :isolated-published)
                             '("described")))
              (should (equal (plist-get health :isolated-draft)
                             '("missing-description")))
              (should (equal (plist-get health :missing-description)
                             '("missing-description")))
              (should (= 2 (length (plist-get health :date-fallback))))))
          (let* ((legacy `((pages . [((id . "legacy")
                                      (title . "旧缓存")
                                      (path . ,described-file)
                                      (tags . [])
                                      (category . "Emacs")
                                      (modified . 1)
                                      (links-to . [])
                                      (linked-from . [])
                                      (theme . "")
                                      (status . "published"))])))
                 (index (org-museum--alist-to-index legacy))
                 (page (gethash "legacy" (org-museum-index-pages index))))
            (should page)
            (should-not (org-museum-page-description page))
            (should-not (org-museum-page-relation-types page))
            (should-not (org-museum-page-relation-diagnostics page))
            (should (= 1 (org-museum-page-created page)))
            (should (eq 'modified-fallback
                        (org-museum-page-date-source page))))
          (let* ((typed (org-museum-test--page
                         "typed" "有类型关系" 2 "Ontology" nil
                         "published" described-file))
                 (roundtrip-pages (make-hash-table :test 'equal))
                 roundtrip)
            (setf (org-museum-page-relation-types typed)
                  '(("目标-一" . "启发影响")))
            (setf (org-museum-page-relation-diagnostics typed)
                  '("重复标注：目标-一"))
            (puthash "typed" typed roundtrip-pages)
            (setq roundtrip
                  (org-museum--alist-to-index
                   (org-museum--index-to-alist
                    (make-org-museum-index
                     :pages roundtrip-pages
                     :tags (make-hash-table :test 'equal)
                     :categories (make-hash-table :test 'equal)
                     :graph (make-hash-table :test 'equal)))))
            (let ((restored (gethash "typed"
                                     (org-museum-index-pages roundtrip))))
              (should (equal (org-museum-page-relation-types restored)
                             '(("目标-一" . "启发影响"))))
              (should (equal (org-museum-page-relation-diagnostics restored)
                             '("重复标注：目标-一"))))))
      (delete-directory root t))))

(ert-deftest org-museum-health-reports-duplicate-heading-paths-and-legacy-anchors ()
  "Health diagnostics expose migration risks without rewriting source notes."
  (let* ((root (make-temp-file "org-museum-heading-health-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (source (expand-file-name "pages/notes/page.org" root))
         (output (expand-file-name "exports/html/pages/notes/page.html" root))
         (pages (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (make-directory (file-name-directory output) t)
          (with-temp-file source
            (insert "#+TITLE: Heading health\n#+WIKI_ID: heading-health\n"
                    "* Repeated\n** Child\n* Repeated\n** Child\n"))
          (with-temp-file output
            (insert "<article><h2 id=\"orgabc123\">Repeated</h2>"
                    "<h3 id=\"section-good123456\">Child</h3></article>"))
          (puthash "heading-health"
                   (org-museum-test--page
                    "heading-health" "Heading health" 1 "notes" nil
                    "published" source)
                   pages)
          (let ((health (org-museum--index-health-report pages)))
            (should (equal (plist-get health :duplicate-heading-paths)
                           '(("heading-health" . "Repeated")
                             ("heading-health" . "Repeated / Child"))))
            (should (equal (plist-get health :legacy-anchors)
                           '(("heading-health" . "orgabc123"))))))
      (delete-directory root t))))

(ert-deftest org-museum-external-local-links-are-resolved-and-marked ()
  (let* ((root (make-temp-file "org-museum-local-links-test-" t))
         (source-dir (expand-file-name "pages/Sql" root))
         (source (expand-file-name "source.org" source-dir))
         (target (expand-file-name "target.org" source-dir))
         (external (expand-file-name "queries/查询 & sample.sql" root))
         (external-org (expand-file-name "queries/guide.org" root))
         (missing (expand-file-name "queries/missing.org" root))
         (out-file (expand-file-name "exports/html/pages/Sql/source.html" root))
         (pages (make-hash-table :test 'equal))
         (target-page (org-museum-test--page
                       "target" "目标" 2 "Sql" nil "published" target))
         (source-page (org-museum-test--page
                       "source" "来源" 1 "Sql" nil "published" source))
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (org-museum-root-dir root)
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (dolist (file (list target external external-org))
            (make-directory (file-name-directory file) t)
            (with-temp-file file (insert "fixture")))
          (with-temp-file target
            (insert "#+TITLE: 目标\n#+WIKI_ID: target\n* Stable section\n"))
          (let ((stale-target-html
                 (expand-file-name "exports/html/pages/Sql/target.html" root)))
            (make-directory (file-name-directory stale-target-html) t)
            (with-temp-file stale-target-html
              (insert "<h2 id=\"orgdeadbeef\">Stable section</h2>")))
          (make-directory (file-name-directory source) t)
          (with-temp-file source
            (insert "[[file:target.org][内部]]\n"
                    "[[file:target.org::*Stable section][章节]]\n"
                    "[[file:../../queries/查询 & sample.sql][查询]]\n"
                    "[[file:../../queries/guide.org][指南]]\n"
                    "[[file:../../queries/missing.org][缺失]]\n"))
          (puthash "source" source-page pages)
          (puthash "target" target-page pages)
          (with-temp-buffer
            (setq buffer-file-name source)
            (insert "[[file:target.org][内部]]\n"
                    "[[file:target.org::*Stable section][章节]]\n"
                    "[[file:../../queries/查询 & sample.sql][查询]]\n"
                    "[[file:../../queries/guide.org][指南]]\n"
                    "[[file:../../queries/missing.org][缺失]]\n")
            ;; Link lookup may perform another regexp search.  Rewriting must
            ;; still replace the original Org link rather than that search.
            (let ((fragment-function
                   (symbol-function 'org-museum--file-link-fragment)))
              (cl-letf (((symbol-function 'org-museum--file-link-fragment)
                         (lambda (page search)
                           (prog1 (funcall fragment-function page search)
                             (string-match "clobber" "clobber")))))
                (org-museum--rewrite-org-museum-links
                 (current-buffer) out-file source)))
            (should (string-match-p "target.html" (buffer-string)))
            (should (string-match-p
                     "target.html#section-[0-9a-f]\\{12\\}"
                     (buffer-string)))
            (should-not (string-match-p "orgdeadbeef" (buffer-string)))
            (should (string-match-p
                     (regexp-quote (replace-regexp-in-string "\\\\" "/" external))
                     (buffer-string))))
          (with-temp-buffer
            (insert (format
                     (concat "<a href=\"%s\">查询</a>"
                             "<a href=\"%s\">指南</a>"
                             "<a href=\"%s\">缺失</a>")
                     (org-museum--path-to-file-url external)
                     (org-museum--path-to-file-url
                      (concat (file-name-sans-extension external-org) ".html"))
                     (org-museum--path-to-file-url missing)))
            (org-museum--pp-annotate-local-file-links)
            (should (string-match-p
                     "data-museum-local-file=\"existing\"" (buffer-string)))
            (should (string-match-p "data-local-path=\".*&amp; sample.sql\""
                                    (buffer-string)))
            (should (string-match-p "data-copy-local-path" (buffer-string)))
            (should (string-match-p "data-local-path=\".*guide.org\""
                                    (buffer-string)))
            (should (string-match-p
                     "data-museum-local-file=\"missing\"" (buffer-string))))
          (let ((health (org-museum--index-health-report pages)))
            (should (= (length (plist-get health :local-external)) 3))
            (should (= (length (plist-get health :local-missing)) 1)))
          ;; Local-link health checks must stay lightweight.  Building a full
          ;; Org AST here made `org-museum-status' take minutes on 12 pages.
          (cl-letf (((symbol-function 'org-element-parse-buffer)
                     (lambda (&rest _args)
                       (ert-fail "local-link scan built a full Org AST"))))
            (should (= (length
                        (org-museum--page-local-file-links source-page pages))
                       3))))
      (delete-directory root t))))

(ert-deftest org-museum-wiki-links-remain-relative-publish-links ()
  "A generated Wiki page link is not reinterpreted as a local file link."
  (let* ((root (make-temp-file "org-museum-wiki-export-test-" t))
         (source (expand-file-name "pages/source.org" root))
         (target (expand-file-name "pages/target.org" root))
         (out-file (expand-file-name "exports/html/pages/source.html" root))
         (pages (make-hash-table :test 'equal))
         (org-museum-root-dir root)
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (with-temp-file source
            (insert "[[wiki:target][Wiki]]\n"
                    "[[wiki:target.org][Wiki Org suffix]]\n"
                    "[[museum:target][Museum]]\n"
                    "[[id:target][ID]]\n"))
          (with-temp-file target
            (insert "#+TITLE: Target\n#+WIKI_ID: target\n"))
          (puthash "source"
                   (org-museum-test--page
                    "source" "Source" 1 nil nil "published" source)
                   pages)
          (puthash "target"
                   (org-museum-test--page
                    "target" "Target" 1 nil nil "published" target)
                   pages)
          (with-temp-buffer
            (setq buffer-file-name source)
            (insert "[[wiki:target][Wiki]]\n"
                    "[[wiki:target.org][Wiki Org suffix]]\n"
                    "[[museum:target][Museum]]\n"
                    "[[id:target][ID]]\n")
            (org-museum--rewrite-org-museum-links
             (current-buffer) out-file source)
            (dolist (description '("Wiki" "Wiki Org suffix" "Museum" "ID"))
              (should (string-match-p
                       (regexp-quote
                        (format "[[file:target.html][%s]]" description))
                       (buffer-string))))
            (should-not (string-match-p "[A-Za-z]:[/\\\\]"
                                        (buffer-string)))))
      (delete-directory root t))))

(ert-deftest org-museum-stale-export-preview-and-cleanup-stay-in-pages-root ()
  (let* ((root (make-temp-file "org-museum-cleanup-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (source (expand-file-name "pages/Emacs/current.org" root))
         (current (expand-file-name "exports/html/pages/Emacs/current.html" root))
         (stale (expand-file-name "exports/html/pages/old.html" root))
         (outside (expand-file-name "exports/html/index.html" root))
         (pages (make-hash-table :test 'equal))
         (page (org-museum-test--page
                "current" "当前页面" 100 "Emacs" nil "published" source))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (puthash "current" page pages)
          (dolist (file (list source current stale outside))
            (make-directory (file-name-directory file) t)
            (with-temp-file file (insert "fixture")))
          (should (equal (org-museum-preview-stale-exports) (list stale)))
          (should-not
           (org-museum--safe-page-html-p outside
                                         (expand-file-name
                                          "exports/html/pages" root)))
          (cl-letf (((symbol-function 'file-symlink-p)
                     (lambda (_file) "simulated-target")))
            (should-not
             (org-museum--safe-page-html-p stale
                                           (expand-file-name
                                            "exports/html/pages" root))))
          (should (file-exists-p stale))
          (should (= (org-museum--clean-stale-exports) 1))
          (should-not (file-exists-p stale))
          (should (file-exists-p current))
          (should (file-exists-p outside))
          (org-museum--write-export-manifest)
          (let ((manifest
                 (expand-file-name
                  "exports/html/.org-museum-manifest.json" root)))
            (should (file-exists-p manifest))
            (with-temp-buffer
              (insert-file-contents manifest)
              (should (search-forward "\"schemaVersion\":1" nil t))
              (should (search-forward "Emacs/current.html" nil t)))))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-failure-skips-manifest-and-cleanup ()
  (let* ((root (make-temp-file "org-museum-failed-export-test-" t))
         (org-museum-root-dir root)
         (org-museum-open-browser-after-export nil)
         (org-museum-clean-stale-html-on-full-export t)
         (pages (make-hash-table :test 'equal))
         (page (org-museum-test--page
                "broken" "导出失败" 100 "Emacs" nil "published"
                (expand-file-name "pages/broken.org" root)))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (clean-called nil)
         (manifest-called nil)
         (index-called nil)
         (graph-called nil))
    (unwind-protect
        (progn
          (puthash "broken" page pages)
          (cl-letf (((symbol-function 'org-museum-index-build)
                     (lambda (&optional _force) org-museum--index))
                    ((symbol-function 'org-museum--ensure-css-deployed)
                     (lambda () nil))
                    ((symbol-function 'org-museum-export-page)
                     (lambda (&rest _args) (error "fixture failure")))
                    ((symbol-function 'org-museum--generate-index-page)
                     (lambda () (setq index-called t)))
                    ((symbol-function 'org-museum-export-graph)
                     (lambda (&rest _args)
                       (setq graph-called t)
                       "graph.html"))
                    ((symbol-function 'org-museum--report-failures)
                     (lambda (_failures) nil))
                    ((symbol-function 'org-museum--write-export-manifest)
                     (lambda () (setq manifest-called t)))
                    ((symbol-function 'org-museum--clean-stale-exports)
                     (lambda () (setq clean-called t))))
            (should-error (org-museum-export-all)
                          :type 'org-museum-export-failed))
          (should-not manifest-called)
          (should-not clean-called)
          (should-not index-called)
          (should-not graph-called))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-restores-page-html-after-failure ()
  (let* ((root (make-temp-file "org-museum-export-rollback-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-open-browser-after-export nil)
         (source (expand-file-name "pages/broken.org" root))
         (output (expand-file-name "exports/html/pages/broken.html" root))
         (pages (make-hash-table :test 'equal))
         (page (org-museum-test--page
                "broken" "Broken" 1 "Test" nil "published" source))
         (org-museum--index
          (make-org-museum-index
           :pages pages :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (make-directory (file-name-directory output) t)
          (with-temp-file source (insert "#+TITLE: Broken\n"))
          (with-temp-file output (insert "OLD HTML"))
          (puthash "broken" page pages)
          (cl-letf (((symbol-function 'org-museum-index-build)
                     (lambda (&optional _force) org-museum--index))
                    ((symbol-function 'org-museum--ensure-css-deployed)
                     #'ignore)
                    ((symbol-function 'org-museum--hljs-assets) #'ignore)
                    ((symbol-function 'org-museum--ensure-d3-deployed) #'ignore)
                    ((symbol-function 'org-museum-export-page)
                     (lambda (&rest _args)
                       (with-temp-file output (insert "PARTIAL HTML"))
                       (error "fixture export failure")))
                    ((symbol-function 'org-museum--report-failures) #'ignore))
            (should-error (org-museum--export-all-current)
                          :type 'org-museum-export-failed))
          (should (equal (org-museum-test--file-string output) "OLD HTML")))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-restores-resources-after-early-failure ()
  (let* ((root (make-temp-file "org-museum-resource-rollback-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir nil)
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (css (org-museum--css-output-path))
         (new-resource (org-museum--d3-resource-path)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory css) t)
          (with-temp-file css (insert "OLD CSS"))
          (cl-letf (((symbol-function 'org-museum--scan-files)
                     (lambda () nil))
                    ((symbol-function 'org-museum--export-all-transaction)
                     (lambda ()
                       (with-temp-file css (insert "PARTIAL CSS"))
                       (with-temp-file new-resource (insert "PARTIAL D3"))
                       (error "fixture resource failure"))))
            (should-error (org-museum--export-all-current)
                          :type 'org-museum-export-failed))
          (should (equal (org-museum-test--file-string css) "OLD CSS"))
          (should-not (file-exists-p new-resource)))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-restores-partly-cleaned-stale-pages ()
  (let* ((root (make-temp-file "org-museum-stale-rollback-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir nil)
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-clean-stale-html-on-full-export t)
         (stale-one (expand-file-name "exports/html/pages/old-one.html" root))
         (stale-two (expand-file-name "exports/html/pages/old-two.html" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory stale-one) t)
          (with-temp-file stale-one (insert "OLD ONE"))
          (with-temp-file stale-two (insert "OLD TWO"))
          (cl-letf (((symbol-function 'org-museum--scan-files)
                     (lambda () nil))
                    ((symbol-function 'org-museum--export-all-transaction)
                     (lambda ()
                       (delete-file stale-one)
                       (error "fixture cleanup failure"))))
            (should-error (org-museum--export-all-current)
                          :type 'org-museum-export-failed))
          (should (equal (org-museum-test--file-string stale-one) "OLD ONE"))
          (should (equal (org-museum-test--file-string stale-two) "OLD TWO")))
      (delete-directory root t))))

(ert-deftest org-museum-stale-cleanup-refuses-empty-index ()
  (let* ((root (make-temp-file "org-museum-empty-cleanup-test-" t))
         (org-museum-root-dir root)
         (org-museum-export-dir "exports/html/pages")
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal)))
         (stale (expand-file-name "exports/html/pages/stale.html" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory stale) t)
          (with-temp-file stale (insert "must survive"))
          (should-error (org-museum-preview-stale-exports) :type 'user-error)
          (should-error (org-museum--clean-stale-exports) :type 'user-error)
          (should (file-exists-p stale)))
      (delete-directory root t))))

(ert-deftest org-museum-stale-cleanup-refuses-out-of-project-pages-root ()
  (let* ((root (make-temp-file "org-museum-traversal-cleanup-test-" t))
         (org-museum-root-dir (expand-file-name "museum" root))
         (org-museum-export-dir "../outside")
         (pages (make-hash-table :test 'equal))
         (page (org-museum-test--page
                "current" "当前页面" 100 "Emacs" nil "published"
                (expand-file-name "museum/pages/current.org" root)))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory org-museum-root-dir t)
          (make-directory (expand-file-name "outside" root) t)
          (puthash "current" page pages)
          (should-error (org-museum-preview-stale-exports) :type 'user-error))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-skips-cleanup-when-safety-check-refuses ()
  (let ((org-museum-root-dir "c:/museum")
        (org-museum-export-dir "exports/html/pages")
        warning)
    (cl-letf (((symbol-function 'org-museum--clean-stale-exports)
               (lambda ()
                 (user-error
                  "Org Museum refuses cleanup outside the museum root")))
              ((symbol-function 'display-warning)
               (lambda (_type message &optional _level _buffer-name)
                 (setq warning message))))
      (should (= (org-museum--clean-stale-exports-if-safe) 0))
      (should (string-match-p "Stale cleanup skipped" warning))
      (should (string-match-p "refuses cleanup outside" warning))
      (should (string-match-p "exports/html/pages" warning)))
    (cl-letf (((symbol-function 'org-museum--clean-stale-exports)
               (lambda () (error "disk write failed"))))
      (should-error (org-museum--clean-stale-exports-if-safe)
                    :type 'error))))

(ert-deftest org-museum-zero-link-graph-keeps-the-obsidian-style-canvas ()
  (let* ((root (make-temp-file "org-museum-zero-graph-test-" t))
         (org-museum-root-dir root)
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-category-label-alist '(("Sql" . "SQL")))
         (pages (make-hash-table :test 'equal))
         (draft (org-museum-test--page
                 "duckdb-note" "DuckDB 笔记" 100 "Sql" nil "draft"))
         (published (org-museum-test--page
                     "emacs-note" "Emacs 笔记" 90 "Emacs" nil "published"))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (puthash "duckdb-note" draft pages)
          (puthash "emacs-note" published pages)
          (let* ((json (org-museum--generate-graph-json))
                 (html (org-museum--build-graph-html
                        json "resources/org-museum.css" "resources/d3.v7.min.js")))
            (should (string-match-p "\"status\":\"draft\"" json))
            (should (string-match-p "\"group\":\"SQL\"" json))
            (should (string-match-p "graph-zero-notice" html))
            (should (string-match-p "graph-isolated-fallback" html))
            (should (string-match-p "graph-isolated-list" html))
            (should (string-search "copy.textContent='复制链接'" html))
            (should (string-match-p
                     (regexp-quote "copyWikiLink('[[wiki:'") html))
             (should (string-match-p "graph-copy-status" html))
             (should (string-match-p "rel=\\\"icon\\\" href=\\\"data:,\\\"" html))
             (should (string-match-p "setAttribute('aria-pressed'" html))
            (should (string-match-p "navigator.clipboard" html))
            (should (string-match-p "document.execCommand('copy')" html))
            (should (string-match-p "复制失败，请手动复制" html))
            (should (string-search "org-museum-graph-network.js" html))
            (should (string-match-p
                     (regexp-quote ".attr('role','group')") html))
            (should-not (string-match-p
                         (regexp-quote ".attr('role','img')") html))
            (should (string-match-p "graph-node-neighbour" html))
            (should (string-match-p "graph-triage-panel" html))
            (should (string-match-p "graph-zero-notice" html))
            (should-not
             (string-match-p
              "if(links.length===0)[[:space:]]*{[^}]*return;" html))))
      (delete-directory root t))))

(ert-deftest org-museum-graph-keeps-reciprocal-page-connections-editable ()
  "Each authored direction retains an independent editable edge identity."
  (let* ((pages (make-hash-table :test 'equal))
         (alpha (org-museum-test--page "alpha" "Alpha" 100))
         (beta (org-museum-test--page "beta" "Beta" 90))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (setf (org-museum-page-links-to alpha) '("beta")
          (org-museum-page-linked-from alpha) '("beta")
          (org-museum-page-relation-types alpha) '(("beta" . "相关"))
          (org-museum-page-links-to beta) '("alpha")
          (org-museum-page-linked-from beta) '("alpha")
          (org-museum-page-relation-types beta) '(("alpha" . "相关")))
    (puthash "alpha" alpha pages)
    (puthash "beta" beta pages)
    (let* ((json-array-type 'list)
           (json-object-type 'alist)
           (data (json-read-from-string (org-museum--generate-graph-json)))
           (links (alist-get 'links data))
           (nodes (alist-get 'nodes data)))
      (should (= 2 (length links)))
      (should (equal '("alpha" "beta")
                     (sort (mapcar (lambda (edge) (alist-get 'ownerId edge)) links)
                           #'string<)))
      (should (seq-every-p (lambda (edge) (equal "相关" (alist-get 'type edge))) links))
      (should (equal '(1 1)
                     (sort (mapcar (lambda (node) (alist-get 'degree node)) nodes)
                           #'<))))))

(ert-deftest org-museum-relation-annotations-label-only-explicit-outgoing-links ()
  "Repeated Unicode relation metadata annotates, but never creates, edges."
  (let* ((root (make-temp-file "org-museum-relation-type-test-" t))
         (source (expand-file-name "source.org" root))
         (target (expand-file-name "target.org" root))
         (missing (expand-file-name "missing.org" root))
         (pages (make-hash-table :test 'equal))
         (index (make-org-museum-index
                 :pages pages
                 :tags (make-hash-table :test 'equal)
                 :categories (make-hash-table :test 'equal)
                 :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "#+TITLE: Source\n#+WIKI_ID: source\n"
                    "#+MUSEUM_RELATION: target | 前置依赖\n"
                    "#+MUSEUM_RELATION: target | 冲突类型\n"
                    "#+MUSEUM_RELATION: missing | 启发影响\n\n"
                    "[[wiki:target][Target]]\n"))
          (with-temp-file target
            (insert "#+TITLE: Target\n#+WIKI_ID: target\n"))
          (with-temp-file missing
            (insert "#+TITLE: Missing\n#+WIKI_ID: missing\n"))
          (mapc (lambda (file)
                  (let ((page (org-museum--parse-page-metadata file)))
                    (puthash (org-museum-page-id page) page pages)))
                (list source target missing))
          (cl-letf (((symbol-function 'org-museum--org-roam-db-linked-page-ids)
                     (lambda (&rest _) nil)))
            (org-museum--scan-resolve-links index))
          (let ((page (gethash "source" pages)))
            (should (equal '(("target" . "前置依赖"))
                           (org-museum-page-relation-types page)))
            (should (= 2 (length (org-museum-page-relation-diagnostics page))))))
      (delete-directory root t))))

(ert-deftest org-museum-incremental-update-resolves-relation-annotations ()
  "Single-page refresh validates relation labels like a full index rebuild."
  (let* ((root (make-temp-file "org-museum-relation-incremental-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (pages-dir (expand-file-name "pages" root))
         (source-file (expand-file-name "source.org" pages-dir))
         (target-file (expand-file-name "target.org" pages-dir))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory pages-dir t)
          (with-temp-file target-file
            (insert "#+TITLE: Target\n#+WIKI_ID: target\n"))
          (with-temp-file source-file
            (insert "#+TITLE: Source\n#+WIKI_ID: source\n"
                    "#+MUSEUM_RELATION: target | 启发影响\n\n"
                    "[[wiki:target][Target]]\n"))
          (org-museum--index-register-page
           org-museum--index (org-museum--parse-page-metadata target-file))
          (org-museum--index-update-file-in-place source-file)
          (let ((source (gethash "source" pages)))
            (should (equal (org-museum-page-relation-types source)
                           '(("target" . "启发影响"))))
            (should-not (org-museum-page-relation-diagnostics source)))
          (with-temp-file source-file
            (insert "#+TITLE: Source\n#+WIKI_ID: source\n"
                    "#+MUSEUM_RELATION: target | 启发影响\n"))
          (org-museum--index-update-file-in-place source-file)
          (let ((source (gethash "source" pages)))
            (should-not (org-museum-page-relation-types source))
            (should (string-match-p
                     "no explicit outgoing link: target"
                     (car (org-museum-page-relation-diagnostics source))))))
      (delete-directory root t))))

(ert-deftest org-museum-page-rename-rewrites-relation-annotation-targets ()
  "Typed-link metadata follows the same transactional rename as the Org link."
  (let* ((root (make-temp-file "org-museum-relation-rename-test-" t))
         (file (expand-file-name "source.org" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "."))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+MUSEUM_RELATION: old-id | 自定义类型\n"
                    "[[wiki:old-id][Old]]\n"))
          (should (= 1 (org-museum--update-links-globally
                        "old-id" "new-id" (list file))))
          (with-temp-buffer
            (insert-file-contents file)
            (should (search-forward
                     "#+MUSEUM_RELATION: new-id | 自定义类型" nil t))
            (should (search-forward "[[wiki:new-id][Old]]" nil t))))
      (delete-directory root t))))

(ert-deftest org-museum-health-includes-relation-annotation-diagnostics ()
  "Invalid manual relation labels remain visible to index health checks."
  (let* ((pages (make-hash-table :test 'equal))
         (page (org-museum-test--page "alpha" "Alpha" 0)))
    (setf (org-museum-page-relation-diagnostics page)
          '("relation annotation has no explicit outgoing link: beta"))
    (puthash "alpha" page pages)
    (let ((health (org-museum--index-health-report pages)))
      (should (equal '(("alpha" . "relation annotation has no explicit outgoing link: beta"))
                     (plist-get health :relation-annotations))))))

(ert-deftest org-museum-graph-keeps-different-reciprocal-types-directional ()
  "Reciprocal links with different author labels remain two factual arrows."
  (let* ((pages (make-hash-table :test 'equal))
         (alpha (org-museum-test--page "alpha" "Alpha" 100))
         (beta (org-museum-test--page "beta" "Beta" 90))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (setf (org-museum-page-links-to alpha) '("beta")
          (org-museum-page-linked-from alpha) '("beta")
          (org-museum-page-relation-types alpha) '(("beta" . "属于"))
          (org-museum-page-links-to beta) '("alpha")
          (org-museum-page-linked-from beta) '("alpha")
          (org-museum-page-relation-types beta) '(("alpha" . "启发影响")))
    (puthash "alpha" alpha pages)
    (puthash "beta" beta pages)
    (let* ((json-array-type 'list)
           (json-object-type 'alist)
           (data (json-read-from-string (org-museum--generate-graph-json)))
           (links (alist-get 'links data)))
      (should (= 2 (length links)))
      (should (equal '(("alpha" "beta" "属于")
                       ("beta" "alpha" "启发影响"))
                     (sort (mapcar (lambda (edge)
                                     (list (alist-get 'source edge)
                                           (alist-get 'target edge)
                                           (alist-get 'type edge)))
                                   links)
                           (lambda (a b) (string< (car a) (car b)))))))))

(ert-deftest org-museum-graph-keeps-isolated-pages-beside-linked-clusters ()
  "An isolated page remains discoverable when other pages form a cluster."
  (should-not (default-value 'org-museum-graph-exclude-orphans))
  (let* ((pages (make-hash-table :test 'equal))
         (alpha (org-museum-test--page "alpha" "Alpha" 100))
         (beta (org-museum-test--page "beta" "Beta" 90))
         (orphan (org-museum-test--page "orphan" "Orphan" 80))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (setf (org-museum-page-links-to alpha) '("beta")
          (org-museum-page-linked-from beta) '("alpha"))
    (puthash "alpha" alpha pages)
    (puthash "beta" beta pages)
    (puthash "orphan" orphan pages)
    (let* ((json-array-type 'list)
           (json-object-type 'alist)
           (data (json-read-from-string (org-museum--generate-graph-json)))
           (nodes (alist-get 'nodes data))
           (orphan-node
            (seq-find (lambda (node)
                        (equal (alist-get 'id node) "orphan"))
                      nodes)))
      (should (= 3 (length nodes)))
      (should orphan-node)
      (should (= 0 (alist-get 'degree orphan-node))))
    ;; A relationship-only view remains an explicit, reversible choice.
    (let* ((org-museum-graph-exclude-orphans t)
           (json-array-type 'list)
           (json-object-type 'alist)
           (data (json-read-from-string (org-museum--generate-graph-json)))
           (nodes (alist-get 'nodes data)))
      (should (= 2 (length nodes)))
      (should-not
       (seq-find (lambda (node)
                   (equal (alist-get 'id node) "orphan"))
                 nodes)))))

(ert-deftest org-museum-graph-selects-before-opening-an-article ()
  "Click and Space select; double-click and Enter open the article."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-search
             ".on('click',function(_event,node){selectNode(node,true);})" graph))
    (should (string-search
             ".on('dblclick',function(_event,node){openNode(node);})" graph))
    (should (string-search
             "if(event.key==='Enter'){event.preventDefault();openNode(node);}" graph))
    (should (string-search "url.searchParams.set('focus',state.selectedId)" graph))
    (should (string-search "params.get('focus')" graph))))

(ert-deftest org-museum-graph-adapts-layout-to-a-sparse-relation-set ()
  "The active graph uses factual edges for layout and visible nodes."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum-graph-network.js" org-museum-test--repo-root))
    (let ((source (buffer-string)))
      (should (string-search "var visible = visibleNodes()" source))
      (should (string-search "graph.links.filter(function (edge)" source))
      (should (string-search "d3.forceSimulation(activeNodes)" source)))))

(ert-deftest org-museum-graph-keeps-click-selection-reliable-after-drag-binding ()
  "Small pointer movement must not turn an ordinary node click into a drag."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-search "d3.drag().clickDistance(4)" graph))))

(ert-deftest org-museum-graph-exposes-reading-and-triage-workflows ()
  "Graph scope controls should not duplicate the global bookshelf rail."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-search "class=\"graph-commandbar\"" graph))
    (should-not (string-search "class=\"museum-graph-rail\"" graph))
    (should (string-search "data-graph-view=\"relations\"" graph))
    (should (string-search "data-graph-view=\"triage\"" graph))
    (should (string-search "id=\"graph-triage-panel\"" graph))
    (should (string-search "var requestedView=graphParams.get('view')||'relations';" graph))
    (should (string-search "function categoryLabel(value)" graph))))

(ert-deftest org-museum-graph-workbench-has-responsive-reading-regions ()
  "Wide graph pages use an inspector rail; narrower pages preserve document flow."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (dolist (pattern '("@media (min-width: 1200px)"
                       "grid-template-columns: minmax(0, 1fr) 320px;"
                       "graph-page .graph-commandbar"
                       "graph-page .graph-triage-panel"
                       "@media (max-width: 820px)"))
      (goto-char (point-min))
      (should (search-forward pattern nil t)))))

(ert-deftest org-museum-graph-uses-lightweight-progressive-labels ()
  "The redesigned graph keeps nodes circular and reveals text progressively."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should-not (string-search "graph-node-card" graph))
    (should-not (string-search "graph-minimap" graph))
    (should (string-search "event.transform.k>=0.62" graph))
    (should (string-search "event.transform.k>=0.95" graph))
    (should (string-search "event.transform.k>=1.05" graph))
    (should (string-search "function fitView(ids)" graph))
    (should (string-search "localStorage.getItem(layoutStorageKey)" graph))
    (should (string-search "id=\"graph-relation-filter\"" graph))))

(ert-deftest org-museum-graph-exposes-topology-layout-modes ()
  "The topology picker exposes all twelve grouped graph arrangements."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (dolist (needle '("拓扑语义层级流" "Dagre 严格分层" "纵向层级树"
                      "横向层级树" "有机力导向" "社区重心极坐标"
                      "分组环形" "同心圆同轴径向" "星系辐射"
                      "蒲公英扇形径向" "轮辐辐射骨架" "同质正交网格"
                      "层级结构" "网状结构" "辐射结构" "网格结构"
                      "id=\"graph-layout-search\"" "function setLayoutMode(mode)"
                      "localStorage.setItem('org-museum-graph-layout'"))
      (should (string-search needle graph)))))

(ert-deftest org-museum-graph-edits-use-org-source-of-truth ()
  "Graph mutations survive rescans and reject stale source hashes."
  (let* ((root (make-temp-file "org-museum-network-" t))
         (backup (make-temp-file "org-museum-network-backup-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir nil)
         (org-museum-curation-backup-directory backup)
         (org-museum--index nil)
         (source (expand-file-name "pages/a.org" root))
         (target (expand-file-name "pages/b.org" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (with-temp-file source
            (insert "#+TITLE: Alpha\n#+WIKI_ID: alpha\n\n* Reading\nSee [[wiki:beta][Beta]].\n"))
          (with-temp-file target
            (insert "#+TITLE: Beta\n#+WIKI_ID: beta\n"))
          (org-museum-index-build t)
          (cl-letf (((symbol-function 'org-museum--export-graph-current)
                     (lambda (&rest _args) nil)))
            (let* ((request `(("action" . "upsert") ("ownerId" . "alpha")
                              ("targetId" . "beta")
                              ("expectedSha256" . ,(org-museum--curation-sha256 source))
                              ("type" . "前置") ("label" . "先读 Beta")
                              ("direction" . "both") ("weight" . 2)
                              ("style" . "dashed")))
                   (graph (org-museum--graph-edit-edge request))
                   (data (let ((json-object-type 'alist) (json-array-type 'list))
                           (json-read-from-string graph)))
                   (edge (car (cdr (assq 'links data)))))
              (should (equal (cdr (assq 'type edge)) "前置"))
              (should (equal (cdr (assq 'label edge)) "先读 Beta"))
              (should (equal (cdr (assq 'direction edge)) "both"))
              (should (= (cdr (assq 'weight edge)) 2))
              (should (equal (cdr (assq 'style edge)) "dashed"))
              (should (string-search "MUSEUM_GRAPH_EDGE" (org-museum-test--file-string source)))
              (should-error (org-museum--graph-edit-edge request)
                            :type 'org-museum-curation-error))
            (let* ((graph (org-museum--graph-edit-edge
                           `(("action" . "delete") ("ownerId" . "alpha")
                             ("targetId" . "beta")
                             ("expectedSha256" . ,(org-museum--curation-sha256 source)))))
                   (data (let ((json-object-type 'alist) (json-array-type 'list))
                           (json-read-from-string graph))))
              (should (= (length (cdr (assq 'links data))) 0))
              (should (string-search "[[wiki:beta][Beta]]"
                                     (org-museum-test--file-string source))))
            (let* ((graph (org-museum--graph-edit-edge
                           `(("action" . "upsert") ("ownerId" . "beta")
                             ("targetId" . "alpha")
                             ("expectedSha256" . ,(org-museum--curation-sha256 target))
                             ("type" . "反例") ("label" . "对照 Alpha")
                             ("direction" . "reverse") ("weight" . 1.5)
                             ("style" . "dotted"))))
                   (data (let ((json-object-type 'alist) (json-array-type 'list))
                           (json-read-from-string graph)))
                   (edge (car (cdr (assq 'links data)))))
              (should (= (length (cdr (assq 'links data))) 1))
              (should (equal (cdr (assq 'source edge)) "alpha"))
              (should (equal (cdr (assq 'target edge)) "beta"))
              (should (equal (cdr (assq 'ownerId edge)) "beta"))))
          (let ((before (org-museum-test--file-string target)))
            (cl-letf (((symbol-function 'org-museum--export-graph-current)
                       (lambda (&rest _args) (error "fixture export failure"))))
              (should-error
               (org-museum--graph-edit-edge
                `(("action" . "delete") ("ownerId" . "beta")
                  ("targetId" . "alpha")
                  ("expectedSha256" . ,(org-museum--curation-sha256 target))))
               :type 'org-museum-curation-error))
            (should (equal before (org-museum-test--file-string target)))))
      (delete-directory root t)
      (delete-directory backup t))))

(ert-deftest org-museum-graph-keeps-isolated-focus-in-triage-context ()
  "A focused orphan should open its queue without dimming the factual network."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-search
             "if(focusId&&state.view==='relations'&&isolatedNodes.some" graph))
    (should (string-search
             "activeNeighborhood=(node.degree||0)>0?neighborhood(node):null" graph))))

(ert-deftest org-museum-graph-stacks-a-compact-relation-path-on-mobile ()
  "Mobile graph labels shorten while retaining full names for assistive tech."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum-graph-network.js" org-museum-test--repo-root))
    (let ((source (buffer-string)))
      (should (string-search "window.innerWidth <= 600 ? 9 : 16" source))
      (should (string-search "shortName(node.name)" source))
      (should (string-search "item.append('title')" source))
      (should (string-search "nodeSelection.select('title').text" source)))))

(ert-deftest org-museum-graph-keeps-triage-summary-inside-its-note ()
  "A queued note expands its own summary without reviving relation details."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-search "row.dataset.nodeId=node.id" graph))
    (should (string-search "summary.className='graph-isolated-summary'" graph))
    (should (string-search "summary.hidden=!summary.hidden" graph))))

(ert-deftest org-museum-full-export-keeps-heading-anchors-stable ()
  "Repeated full exports keep public section links stable and unique."
  (let* ((root (make-temp-file "org-museum-stable-anchor-test-" t))
         (pages-dir (expand-file-name "pages/Test" root))
         (org-file (expand-file-name "stable.org" pages-dir))
         (html-file
          (expand-file-name "exports/html/pages/Test/stable.html" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-css-file "resources/org-museum.css")
         (org-museum-open-browser-after-export nil)
         (org-museum--plugin-dir org-museum-test--repo-root)
         first-ids second-ids)
    (unwind-protect
        (progn
          (make-directory pages-dir t)
          (with-temp-file org-file
            (insert
             "#+TITLE: Stable anchors\n"
             "#+WIKI_ID: stable\n"
             "#+CATEGORY: Test\n\n"
             "* Parent\n"
             "** Repeated\n"
             "** Repeated\n"
             "* Custom\n"
             ":PROPERTIES:\n:CUSTOM_ID: kept-custom\n:END:\n"))
          (cl-labels
              ((heading-ids ()
                 (with-temp-buffer
                   (insert-file-contents html-file)
                   (goto-char (point-min))
                   (let (ids)
                     (while (re-search-forward
                             "<h[2-4][^>]* id=\"\\([^\"]+\\)\"" nil t)
                       (let ((id (match-string-no-properties 1)))
                         (unless (string-prefix-p "local-" id)
                           (push id ids))))
                     (nreverse ids)))))
            (cl-letf (((symbol-function 'url-copy-file)
                       (lambda (&rest _args)
                         (error "fixture export must not use the network")))
                      ((symbol-function 'browse-url)
                       (lambda (&rest _args) nil)))
              (org-museum-export-all)
              (setq first-ids (heading-ids))
              (org-museum-export-all)
              (setq second-ids (heading-ids)))
            (should (equal first-ids second-ids))
            (should (member "kept-custom" first-ids))
            (should (= (length first-ids)
                       (length (delete-dups (copy-sequence first-ids)))))
            (should (cl-every
                     (lambda (id)
                       (or (equal id "kept-custom")
                           (string-match-p "\\`section-[0-9a-f]\\{12\\}\\'" id)))
                     first-ids))))
      (delete-directory root t))))

(ert-deftest org-museum-heading-inventory-keeps-sibling-paths-distinct ()
  "Different sibling sections must never reuse a cached outline path."
  (let* ((root (make-temp-file "org-museum-sibling-test-" t))
         (source (expand-file-name "page.org" root))
         (page (org-museum-test--page "siblings" "Siblings" 1 "notes" nil
                                      "published" source)))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "#+TITLE: Siblings\n* Parent\n** First\n*** Detail\n** Second\n"))
          (let* ((inventory (org-museum--source-heading-inventory page))
                 (ids (mapcar (lambda (item) (plist-get item :id)) inventory)))
            (should (equal (mapcar (lambda (item) (plist-get item :path)) inventory)
                           '("Parent" "Parent / First" "Parent / First / Detail" "Parent / Second")))
            (should (= (length ids) (length (delete-dups (copy-sequence ids)))))))
      (delete-directory root t))))

(ert-deftest org-museum-stable-heading-inventory-skips-non-exported-subtrees ()
  "COMMENT and noexport headings must not shift later stable-anchor pairing."
  (let* ((root (make-temp-file "org-museum-export-heading-test-" t))
         (source (expand-file-name "page.org" root))
         (page (org-museum-test--page
                "export-aware" "Export aware" 1 "notes" nil
                "published" source)))
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "#+TITLE: Export aware\n#+WIKI_ID: export-aware\n"
                    "* Visible first\n"
                    "* COMMENT Hidden comment\n** Hidden child\n"
                    "* Hidden tagged :noexport:\n"
                    "* Visible later\n"))
          (let ((expected '("Visible first" "Visible later")))
            (let ((org-mode-hook
                   (list (lambda ()
                           (ert-fail "temporary parser ran org-mode-hook")))))
              (should (equal
                       (mapcar (lambda (heading) (alist-get 'title heading))
                               (org-museum--source-headings page))
                       expected)))
            (cl-letf (((symbol-function 'org-export--selected-trees) nil)
                      ((symbol-function 'org-export--skip-p) nil))
              (should (equal
                       (mapcar (lambda (heading) (alist-get 'title heading))
                               (org-museum--source-headings page))
                       expected)))
            (cl-letf (((symbol-function 'org-export--selected-trees)
                       (lambda () nil)))
              (should (equal
                       (mapcar (lambda (heading) (alist-get 'title heading))
                               (org-museum--source-headings page))
                       expected)))
            (cl-letf (((symbol-function 'org-museum--source-heading-inventory)
                       (lambda (&rest _args)
                         (ert-fail "health check used export anchor inventory"))))
              (let ((org-mode-hook
                     (list (lambda ()
                             (ert-fail "health check ran org-mode-hook")))))
                (should-not (org-museum--page-duplicate-heading-paths page))))))
      (delete-directory root t))))

(ert-deftest org-museum-full-export-fixture ()
  (let* ((root (make-temp-file "org-museum-export-test-" t))
         (pages-dir (expand-file-name "pages/Emacs" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum-css-file "resources/org-museum.css")
         (org-museum-open-browser-after-export nil)
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (org-museum--plugin-dir org-museum-test--repo-root))
    (unwind-protect
        (progn
          (make-directory pages-dir t)
          (with-temp-file (expand-file-name "alpha.org" pages-dir)
            (insert
             "#+TITLE: 中文 & <Alpha>\n"
             "#+WIKI_ID: alpha\n"
             "#+CATEGORY: Emacs\n"
             "#+FILETAGS: :中文:special:\n\n"
             "* 第一节\n正文。\n\n"
             "** 长标题 & 代码\n#+begin_src emacs-lisp\n(message \"ok\")\n#+end_src\n\n"
             "#+begin_src c++\nint main() { return 0; }\n#+end_src\n\n"
             "#+begin_src f#\nlet answer = 42\n#+end_src\n\n"
             "[[wiki:beta][Open Beta]]\n"))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "alpha.org" pages-dir))
            (goto-char (point-max))
            (insert
             "\n** 宽表\n"
             "| 字段一 | 字段二 | 字段三 |\n"
             "|--------+--------+--------|\n"
             "| 很长的内容 | 另一个很长的内容 | 最后一个很长的内容 |\n")
            (write-region (point-min) (point-max)
                          (expand-file-name "alpha.org" pages-dir)))
          (with-temp-file (expand-file-name "beta.org" pages-dir)
            (insert
             "#+TITLE: 第二篇\n"
             "#+WIKI_ID: beta\n"
             "#+CATEGORY: Emacs\n\n"
             "* 内容\n"
             "[[wiki:alpha][返回 Alpha]]\n"))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (&rest _args)
                       (error "fixture export must not use the network")))
                    ((symbol-function 'browse-url)
                     (lambda (&rest _args) nil)))
            (org-museum-export-all))
          (let ((index-file (expand-file-name "exports/html/index.html" root))
                (graph-file (expand-file-name "exports/html/graph.html" root))
                (index-runtime
                 (expand-file-name
                  "exports/html/resources/org-museum-index.js" root))
                (article-runtime
                 (expand-file-name
                  "exports/html/resources/org-museum-article.js" root))
                (graph-runtime
                 (expand-file-name
                  "exports/html/resources/org-museum-graph.js" root))
                (theme-runtime
                 (expand-file-name
                  "exports/html/resources/org-museum-theme.js" root))
                (alpha-file
                 (expand-file-name "exports/html/pages/Emacs/alpha.html" root)))
            (should (file-exists-p index-file))
            (should (file-exists-p graph-file))
            (should (file-exists-p alpha-file))
            (with-temp-buffer
              (insert-file-contents index-file)
              (should (search-forward "museum-index-matrix" nil t))
              (should (search-forward "org-museum-index-data" nil t))
              (goto-char (point-min))
              (should-not (search-forward "<script>" nil t))
              (goto-char (point-min))
              (should (re-search-forward
                       "org-museum-index\\.js\\?v=[0-9a-f]\\{12\\}" nil t))
              (goto-char (point-min))
              (should (re-search-forward
                       "resources/org-museum\\.css\\?v=[0-9a-f]\\{12\\}" nil t)))
            (with-temp-buffer
              (insert-file-contents alpha-file)
              (should (search-forward "data-page-id=\"alpha\"" nil t))
              (goto-char (point-min))
              (should (search-forward "class=\"language-cpp\"" nil t))
              (goto-char (point-min))
              (should (search-forward "class=\"language-fsharp\"" nil t))
              (goto-char (point-min))
              (should-not (search-forward "language-c++" nil t))
              (goto-char (point-min))
              (should-not (search-forward "language-f#" nil t))
              (goto-char (point-min))
              (should-not (search-forward "<script>" nil t))
              (goto-char (point-min))
              (should (re-search-forward
                       "highlight\\.min\\.js\\?v=[0-9a-f]\\{12\\}" nil t))
              (goto-char (point-min))
              (should (search-forward "museum-article-layout" nil t))
              (goto-char (point-min))
              (should (re-search-forward
                       "org-museum-article\\.js\\?v=[0-9a-f]\\{12\\}" nil t))
              (goto-char (point-min))
              (should (search-forward "museum-table-scroll" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-search" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-count" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-clear" nil t))
              (goto-char (point-min))
              (should (search-forward "data-toc-empty" nil t))
              (goto-char (point-min))
              (should (search-forward "graph.html?focus=alpha" nil t))
              (goto-char (point-min))
              (should-not (search-forward "cdn.staticfile.net" nil t)))
            (with-temp-buffer
              (insert-file-contents article-runtime)
              (dolist (needle '("museum-article-identity"
                                "data-current-section"
                                "indexedDB.open('org-museum',1)"
                                "engagedMs"
                                 "progress>=0.03"
                                 "engagedMs>=30000"
                                 "orgMuseumThemeUrl(destination)"
                                 "aria-expanded"
                                "document.body.appendChild(toc)"))
                (goto-char (point-min))
                (should (search-forward needle nil t))))
            (should
             (string-search
              "orgMuseumThemeUrl(target)"
              (org-museum--graph-render-js
               '(:container-id "local-graph"
                 :data-var "graphData"
                 :nav-on-click t))))
            (with-temp-buffer
              (insert-file-contents graph-file)
              (should (search-forward "museum-graph-shell" nil t))
              (goto-char (point-min))
              (should (re-search-forward
                       "<script type=\"application/json\" id=\"graph-data\">\\([^\n]+\\)</script>"
                       nil t))
              (let* ((json-array-type 'list)
                     (json-object-type 'alist)
                     (data (json-read-from-string
                            (match-string-no-properties 1)))
                     (links (alist-get 'links data)))
                (should (= 2 (length links)))
                (should
                 (equal '(("alpha" "beta") ("beta" "alpha"))
                        (sort (mapcar (lambda (edge)
                                        (list (alist-get 'source edge)
                                              (alist-get 'target edge))) links)
                              (lambda (a b) (string< (car a) (car b)))))))
              (goto-char (point-min))
              (should-not (search-forward "<script>" nil t))
              (goto-char (point-min))
              (should (re-search-forward
                       "d3\\.v7\\.min\\.js\\?v=[0-9a-f]\\{12\\}" nil t))
              (should (re-search-forward
                       "org-museum-graph\\.js\\?v=[0-9a-f]\\{12\\}" nil t))
              (goto-char (point-min))
              (should (search-forward "尚未形成知识连线" nil t))
              (goto-char (point-min))
              (should-not (search-forward "https://d3js.org" nil t)))
            (dolist (html-file (list index-file alpha-file graph-file))
              (with-temp-buffer
                (insert-file-contents html-file)
                (should (re-search-forward
                         "org-museum-theme\\.js\\?v=[0-9a-f]\\{12\\}" nil t))
                (goto-char (point-min))
                (should (search-forward
                         "name=\"color-scheme\" content=\"dark light\"" nil t))
                (goto-char (point-min))
                (should (= (how-many "id=\"museum-drawer-backdrop\"")
                           (if (equal html-file alpha-file) 1 0)))))
            (with-temp-buffer
              (insert-file-contents graph-runtime)
              (dolist (needle '("new URLSearchParams(location.search)"
                                "window.addEventListener('popstate'"))
                (goto-char (point-min))
                (should (search-forward needle nil t))))
            (with-temp-buffer
              (insert-file-contents
               (expand-file-name
                "exports/html/resources/org-museum-graph-network.js" root))
              (dolist (needle '("function setGraph(value)"
                                "d3.forceSimulation(activeNodes)"
                                "function visibleNodes()"))
                (goto-char (point-min))
                (should (search-forward needle nil t))))
            (should (file-exists-p index-runtime))
            (should (file-exists-p theme-runtime))
            (dolist (asset '("d3.v7.min.js"
                             "highlight.min.js"
                             "highlight-lisp.min.js"
                             "highlight.monokai.min.css"
                             "org-museum-theme.js"
                             "org-museum-index.js"
                             "org-museum-article.js"
                             "org-museum-graph.js"))
              (should
               (file-exists-p
                (expand-file-name (concat "exports/html/resources/" asset)
                                  root))))))
      (delete-directory root t))))

(ert-deftest org-museum-runtime-status-prefers-repository-and-detects-drift ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-runtime-status-test-" t)))
         (user-emacs-directory root)
         (repo-file (expand-file-name
                     "straight/repos/org-museum.el/org-museum.el" root))
         (build-file (expand-file-name
                      "straight/build/org-museum/org-museum.el" root))
         (org-museum--loaded-source-path build-file)
         (org-museum--loaded-source-hash nil))
    (unwind-protect
        (progn
          (make-directory (file-name-directory repo-file) t)
          (make-directory (file-name-directory build-file) t)
          (with-temp-file repo-file (insert ";; repository current\n"))
          (with-temp-file build-file (insert ";; loaded stale\n"))
          (setq org-museum--loaded-source-hash
                (org-museum--file-content-hash build-file))
          (let ((status (org-museum--runtime-source-status)))
            (should (equal (plist-get status :canonical) repo-file))
            (should (equal (plist-get status :loaded) build-file))
            (should-not (plist-get status :in-sync))))
      (delete-directory root t))))

(ert-deftest org-museum-missing-bundled-resource-never-uses-network ()
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-offline-missing-test-" t)))
         (user-emacs-directory root)
         (org-museum-root-dir root)
         (org-museum--plugin-dir (expand-file-name "plugin/" root))
         (dest (expand-file-name "exports/html/resources/missing.js" root))
         (network-called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'url-copy-file)
                   (lambda (&rest _args) (setq network-called t))))
          (should (fboundp 'org-museum--deploy-bundled-resource))
          (should-error
           (org-museum--deploy-bundled-resource
            "resources/missing.js" dest "Missing runtime"))
          (should-not network-called)
          (should-not (file-exists-p dest)))
      (delete-directory root t))))

(ert-deftest org-museum-runtime-refresh-reenters-once-before-export-work ()
  (let ((org-museum-auto-reload-before-export t)
        (reloaded 0)
        (reentered 0)
        (mutated nil))
    (cl-letf (((symbol-function 'org-museum--runtime-source-status)
               (lambda () '(:in-sync nil)))
              ((symbol-function 'org-museum-reload)
               (lambda () (cl-incf reloaded) t))
              ((symbol-function 'org-museum-test--fresh-export)
               (lambda (value) (cl-incf reentered) value)))
      (should
       (eq (org-museum--run-with-current-runtime
            'org-museum-test--fresh-export '(fresh)
            (lambda () (setq mutated t)))
           'fresh))
      (should (= reloaded 1))
      (should (= reentered 1))
      (should-not mutated))))

(ert-deftest org-museum-runtime-refresh-failure-aborts-before-export-work ()
  (let ((org-museum-auto-reload-before-export t)
        (mutated nil))
    (cl-letf (((symbol-function 'org-museum--runtime-source-status)
               (lambda () '(:in-sync nil)))
              ((symbol-function 'org-museum-reload)
               (lambda () (error "reload failed"))))
      (should-error
       (org-museum--run-with-current-runtime
        'ignore nil (lambda () (setq mutated t))))
      (should-not mutated))))

(ert-deftest org-museum-index-filtering-prioritizes-results-and-migrates-history ()
  (let* ((root (make-temp-file "org-museum-index-priority-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/index.html" root))
         (page (org-museum-test--page
                "duck" "DuckDB" 42 "Sql" '("database") "draft"))
         (html (org-museum--build-index-html
                `(("Sql" . (,page))) "graph.html" out-file)))
    (unwind-protect
        (progn
          (should (string-match-p "<h1>内容索引</h1>" html))
          (should (= 1 (cl-loop with start = 0
                                for at = (string-match
                                          "id=\"org-museum-global-search\"" html start)
                                while at count at
                                do (setq start (1+ at)))))
          (should (string-match-p "class=\"museum-index-dashboard\"" html))
          (dolist (contract '("data-dashboard-metric=\"total\""
                              "id=\"index-type-chart\""
                              "id=\"index-trend-chart\""
                              "id=\"index-dynamic-filters\""
                              "id=\"index-filter-chips\""
                              "function bestMatch(page)"
                              "function renderResults()"))
            (should (string-search contract html)))
          (should (string-match-p "normalizeHeadingTitle" html))
          (should (string-match-p
                   (regexp-quote "if(!headingValid){") html))
          (should (string-match-p "cursor.update(record)" html)))
      (delete-directory root t))))

(ert-deftest org-museum-source-language-prefers-org-keyword-then-chinese-default ()
  (let* ((root (make-temp-file "org-museum-language-test-" t))
         (default-file (expand-file-name "default.org" root))
         (english-file (expand-file-name "english.org" root))
         (org-museum-default-language "zh-CN"))
    (unwind-protect
        (progn
          (with-temp-file default-file (insert "#+TITLE: 中文\n"))
          (with-temp-file english-file
            (insert "#+TITLE: English\n#+LANGUAGE: en\n"))
          (should (equal (org-museum--source-language default-file) "zh-CN"))
          (should (equal (org-museum--source-language english-file) "en")))
      (delete-directory root t))))

(ert-deftest org-museum-document-language-rewrite-preserves-doctype ()
  (let ((org-file (make-temp-file "org-museum-language-html-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file org-file (insert "#+TITLE: 中文\n"))
          (with-temp-buffer
            (insert "<!DOCTYPE html>\n<html lang=\"en\">\n<body></body></html>")
            (org-museum--pp-set-document-language org-file)
            (should (string-prefix-p "<!DOCTYPE html>\n<html lang=\"zh-CN\">"
                                     (buffer-string)))))
      (delete-file org-file))))

(ert-deftest org-museum-mobile-topbar-and-metadata-respect-small-text-floor ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (dolist (needle '(".museum-topbar-link"
                      "min-height: var(--museum-touch-target)"
                      "font-size: 12px"
                      "--museum-meta-font-size: 11px"))
      (goto-char (point-min))
      (should (search-forward needle nil t)))))

(ert-deftest org-museum-desktop-index-uses-space-with-overlay-bookshelf ()
  "The closed overlay shelf reserves no desktop reading space."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "@media (min-width: 1200px)" nil t))
    (should (re-search-forward
             "\\.museum-index-shell[[:space:]\n]*{[^}]*width: 100%;"
             nil t))))

(ert-deftest org-museum-medium-layout-exposes-bookshelf-drawer-trigger ()
  "The shelf remains reachable after it becomes an off-canvas drawer."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "@media (max-width: 1199px)" nil t))
    (should (re-search-forward
             "\\.museum-drawer-toggle[[:space:]\n]*{[^}]*display: inline-flex;"
             nil t))))

(ert-deftest org-museum-mobile-article-defers-secondary-metadata ()
  (let ((page (org-museum-test--page "alpha" "Alpha" 1 "Test" '("tag"))))
    (cl-letf (((symbol-function 'org-museum--page-href)
               (lambda (&rest _args) "pages/alpha.html")))
      (let ((html (org-museum--article-meta-html
                   page "pages/alpha.html" "alpha.org"))
            (runtime (org-museum--script-shell)))
        (should (string-search "museum-article-meta-disclosure" html))
        (should (string-search "<summary>文章信息</summary>" html))
        (should (string-search "metaDisclosure.open=false" runtime))
        (should (string-search "metaMedia.addEventListener" runtime))))))

(ert-deftest org-museum-narrow-article-topbar-keeps-all-actions-reachable ()
  "The four article actions must fit without shrinking their touch targets."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "resources/org-museum.css" org-museum-test--repo-root))
    (should (search-forward "@media (max-width: 380px)" nil t))
    (should (re-search-forward
             "\\.museum-topbar[[:space:]\n]*{[^}]*gap: 10px;[^}]*padding: 0 16px;"
             nil t))
    (should (re-search-forward
             "\\.museum-top-links[[:space:]\n]*{[^}]*gap: 4px;"
             nil t))))

(ert-deftest org-museum-externalizes-executable-runtime-with-content-version ()
  (let* ((root (make-temp-file "org-museum-runtime-assets-test-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-export-dir "exports/html/pages")
         (out-file (expand-file-name "exports/html/pages/alpha.html" root))
         (html (concat "<html><body>"
                       "<script type=\"application/json\" id=\"data\">{}</script>"
                       "<script>window.alpha=1;</script>"
                       "<script>window.beta=2;</script>"
                       "</body></html>")))
    (unwind-protect
        (progn
          (make-directory (file-name-directory out-file) t)
          (let* ((result (org-museum--externalize-page-runtime
                          html out-file 'article))
                 (runtime (expand-file-name
                           "exports/html/resources/org-museum-article.js" root)))
            (should (file-exists-p runtime))
            (should (string-match-p
                     "org-museum-article\\.js\\?v=[0-9a-f]\\{12\\}" result))
            (should (string-match-p "application/json" result))
            (should-not (string-match-p "window\\.alpha" result))
            (with-temp-buffer
              (insert-file-contents runtime)
              (should (search-forward "window.alpha=1" nil t))
              (should (search-forward "window.beta=2" nil t)))))
      (delete-directory root t))))

(ert-deftest org-museum-manual-runtime-prefers-loaded-workspace ()
  "A manually loaded workspace remains authoritative over Straight caches."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-manual-runtime-test-" t)))
         (user-emacs-directory root)
         (workspace (expand-file-name "workspace/org-museum.el" root))
         (straight-repo
          (expand-file-name "straight/repos/org-museum.el/org-museum.el" root))
         (org-museum--loaded-source-path workspace))
    (unwind-protect
        (progn
          (make-directory (file-name-directory workspace) t)
          (make-directory (file-name-directory straight-repo) t)
          (with-temp-file workspace (insert "WORKSPACE"))
          (with-temp-file straight-repo (insert "STRAIGHT"))
          (should (equal (org-museum--canonical-elisp-source-path)
                         workspace)))
      (delete-directory root t))))

(ert-deftest org-museum-manual-workspace-prefers-its-own-resources ()
  "A manually loaded workspace must not deploy stale Straight resources."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-manual-resource-test-" t)))
         (user-emacs-directory root)
         (workspace (expand-file-name "org-roam/" root))
         (workspace-css (expand-file-name "resources/org-museum.css" workspace))
         (straight-css
          (expand-file-name
           "straight/repos/org-museum.el/resources/org-museum.css" root))
         (org-museum--plugin-dir workspace))
    (unwind-protect
        (progn
          (make-directory (file-name-directory workspace-css) t)
          (make-directory (file-name-directory straight-css) t)
          (with-temp-file workspace-css (insert "WORKSPACE"))
          (with-temp-file straight-css (insert "STRAIGHT"))
          (should (equal (org-museum--resource-source-path
                          "resources/org-museum.css")
                         workspace-css)))
      (delete-directory root t))))

(ert-deftest org-museum-topbars-share-one-accessible-theme-control ()
  "Theme actions name their target without contradictory pressed state."
  (dolist (kind '(home article timeline graph related))
    (let ((topbar (org-museum--build-topbar "index.html" kind)))
      (should (= (length (split-string topbar "data-theme-toggle" t)) 2))
      (should (string-match-p
               (regexp-quote "aria-label=\"切换为深色主题\"") topbar))
      (should (string-match "<button[^>]*data-theme-toggle[^>]*>" topbar))
      (should-not (string-search "aria-pressed=" (match-string 0 topbar)))
      (should (string-search "data-theme-system aria-pressed=\"true\"" topbar)))))

(ert-deftest org-museum-all-topbars-expose-one-drawer-trigger ()
  "Every shared shell exposes the same mobile notes drawer."
  (dolist (kind '(home article timeline graph related))
    (let ((topbar (org-museum--build-topbar "index.html" kind)))
      (should (= (length (split-string topbar "data-drawer-toggle" t)) 2))
      (should (string-match-p "aria-label=\"打开全部笔记\"" topbar))))
  (let ((runtime (org-museum--script-shell)))
    (should (string-match-p
             (regexp-quote
              "button.setAttribute('aria-label',open?'关闭全部笔记':'打开全部笔记');")
             runtime)))
  (let ((runtime (org-museum--script-shell)))
    (should-not (string-search "var drawerMedia=" runtime))
    (should (string-search "setPanelAvailable(drawer,false)" runtime))
    (should (string-search "releasePanelBackground" runtime))
    (should (string-search "lockPanelBackground" runtime))))

(ert-deftest org-museum-topbar-unifies-settings-and-model-control ()
  "The topbar merges theme switching and AI model settings into a unified settings menu."
  (let ((ai-topbar (org-museum--build-topbar "ai-center.html" 'ai))
        (home-topbar (org-museum--build-topbar "index.html" 'home)))
    (should (string-search "museum-settings-menu" ai-topbar))
    (should (string-search "museum-settings-menu" home-topbar))
    (should (string-search "data-theme-toggle" ai-topbar))
    (should (string-search "data-theme-system" ai-topbar))
    (should (string-search "data-browser-config" ai-topbar))
    (should (string-search "data-browser-models" ai-topbar))
    (should (string-search "data-browser-load" ai-topbar))
    (should (string-search "museum-settings-ai-section" ai-topbar))
    (should-not (string-search "museum-settings-ai-section" home-topbar))))

(ert-deftest org-museum-related-data-keeps-explicit-direction-and-deduplicates-pairs ()
  (let* ((pages (make-hash-table :test #'equal))
         (alpha (org-museum-test--page "alpha" "Alpha" 2))
         (beta (org-museum-test--page "beta" "Beta" 1))
         (orphan (org-museum-test--page "orphan" "Orphan" 0))
         (draft (org-museum-test--page "draft" "Draft" 3))
         (org-museum--index
          (make-org-museum-index :pages pages
                                 :tags (make-hash-table :test #'equal)
                                 :categories (make-hash-table :test #'equal)
                                 :graph (make-hash-table :test #'equal))))
    (setf (org-museum-page-status draft) "draft"
          (org-museum-page-links-to alpha) '("beta" "draft")
          (org-museum-page-linked-from alpha) '("beta")
          (org-museum-page-links-to beta) '("alpha")
          (org-museum-page-linked-from beta) '("alpha")
          (org-museum-page-linked-from draft) '("alpha"))
    (mapc (lambda (page) (puthash (org-museum-page-id page) page pages))
          (list alpha beta orphan draft))
    (cl-letf (((symbol-function 'org-museum--related-page-alist)
               (lambda (page _out-file) `((id . ,(org-museum-page-id page))))))
      (let* ((data (org-museum--related-data-alist "related.html"))
             (edges (alist-get 'edges data))
             (edge (aref edges 0))
             (page-ids
              (mapcar (lambda (page) (alist-get 'id page))
                      (append (alist-get 'pages data) nil))))
        (should (= 1 (length edges)))
        (should-not (member "draft" page-ids))
        (should (equal "alpha" (alist-get 'source edge)))
        (should (equal "beta" (alist-get 'target edge)))
        (should (eq t (alist-get 'bidirectional edge)))))))

(ert-deftest org-museum-created-date-parses-org-date-and-falls-back-safely ()
  "Creation dates accept valid Org dates and diagnose missing or invalid values."
  (let* ((fallback 12345.0)
         (valid (org-museum--parse-created-date "<2026-09-03 Thu>" fallback))
         (invalid (org-museum--parse-created-date "2026-02-31" fallback))
         (missing (org-museum--parse-created-date nil fallback)))
    (should (eq (cadr valid) 'org-date))
    (should (equal "2026-09-03"
                   (format-time-string "%Y-%m-%d" (seconds-to-time (car valid)))))
    (should (equal invalid (list fallback 'modified-fallback)))
    (should (equal missing (list fallback 'modified-fallback)))))

(ert-deftest org-museum-timeline-orders-creation-and-keeps-explicit-relations ()
  "Timeline data sorts creation events and reuses only explicit Org edges."
  (let* ((pages (make-hash-table :test #'equal))
         (later (org-museum-test--page "later" "Later" 40))
         (earlier (org-museum-test--page "earlier" "Earlier" 30))
         (org-museum--index
          (make-org-museum-index :pages pages
                                 :tags (make-hash-table :test #'equal)
                                 :categories (make-hash-table :test #'equal)
                                 :graph (make-hash-table :test #'equal))))
    (setf (org-museum-page-created later) 20
          (org-museum-page-date-source later) 'org-date
          (org-museum-page-created earlier) 10
          (org-museum-page-date-source earlier) 'org-date
          (org-museum-page-links-to earlier) '("later")
          (org-museum-page-linked-from later) '("earlier"))
    (puthash "later" later pages)
    (puthash "earlier" earlier pages)
    (cl-letf (((symbol-function 'org-museum--related-article-fragment)
               (lambda (_page) "<p>摘要</p>"))
              ((symbol-function 'org-museum--page-href)
               (lambda (id _out-file) (concat "pages/" id ".html"))))
      (let* ((data (org-museum--timeline-data-alist "timeline.html"))
             (timeline-pages (alist-get 'pages data))
             (edges (alist-get 'edges data)))
        (should (= org-museum--index-schema-version 5))
        (should (equal '("earlier" "later")
                       (mapcar (lambda (page) (alist-get 'id page))
                               timeline-pages)))
        (should (= 1 (length edges)))
        (should (equal "earlier" (alist-get 'source (aref edges 0))))
        (should (eq :json-false
                    (alist-get 'bidirectional (aref edges 0))))))))

(ert-deftest org-museum-timeline-age-days-uses-calendar-dates ()
  "A next-afternoon update is one calendar day after creation, not two."
  (let ((page (org-museum-test--page "dated" "Dated" 0)))
    (setf (org-museum-page-created page)
          (float-time (encode-time 0 0 0 3 9 2026))
          (org-museum-page-modified page)
          (float-time (encode-time 0 0 13 4 9 2026)))
    (cl-letf (((symbol-function 'org-museum--page-href)
               (lambda (&rest _args) "pages/dated.html")))
      (should (= 1 (alist-get 'ageDays
                              (org-museum--timeline-page-alist
                               page "timeline.html")))))))

(ert-deftest org-museum-timeline-runtime-keeps-focus-and-history-contracts ()
  "Timeline filters, explicit selection, and history expose stable contracts."
  (let ((script (org-museum--script-timeline)))
    (dolist (needle '("selected&&!matches(selected)"
                      "writeUrl('push')"
                      "setFocus(next,true,true)"
                      "window.addEventListener('popstate'"
                      "if(!pageMap.has(state.focus))state.focus=''"))
      (should (string-search needle script)))))

(ert-deftest org-museum-home-storage-failure-keeps-a-useful-empty-state ()
  (let ((script (org-museum--script-index))
        (html (org-museum--build-index-html nil "graph.html" "index.html")))
    (should (string-search
             "}).then(renderResume).catch(function(){renderResume([]);});"
             script))
    (should-not (string-search
                 ").catch(function(){if(resume)resume.hidden=true;});"
                 script))
    (should (string-search
             "id=\"continue-reading\" class=\"museum-resume\" aria-busy=\"true\""
             html))
    (should (string-search "<strong>继续探索</strong>" html))
    (should (string-search "href=\"#recent-updates\">从全部笔记开始" html))))

(ert-deftest org-museum-timeline-runtime-keeps-interaction-continuity ()
  "Focus, mobile details, and filters update without disruptive scrolling."
  (let ((script (org-museum--script-timeline)))
    (dolist (needle '("function scheduleTimelineUpdate"
                      "function scheduleDesktopGeometry"
                      "function revealWithinViewport"
                      "function buildMobileList"
                      "function applyMobileFocus"
                      "mobileListSignature"
                      "focus({preventScroll:true})"
                      "timeline-filter-open"
                      "filterScroll=scrollY"
                      "document.body.style.position='fixed'"
                      "document.body.style.position=''"
                      "Math.abs(nextWidth-desktop.width)<1"
                      "closest('.timeline-node,.timeline-mobile-node')"
                      "function activeTimelineFocusId()"
                      "var activeId=activeTimelineFocusId()"
                      "focusedId=activeTimelineFocusId()"
                      "var activeNode=activeId&&focusButton(activeId)"
                      "focusControl:focusedId===state.focus"
                      "if(!event.target.closest||!event.target.closest('.timeline-node'))"))
      (should (string-search needle script)))
    (should-not (string-search
                 "coordinator.inputMode==='keyboard'?coordinator.lastFocusId:''"
                 script))
    (should-not (string-search
                 "focusControl:coordinator.inputMode==='keyboard'&&coordinator.lastFocusId===state.focus"
                 script))
    (should-not (string-search "focusCard.scrollIntoView" script))
    (should (string-search "timelineLayout.classList.toggle('has-focus',showInspector)" script))
    (should-not (string-search "function positionFocusCard" script))
    (should-not (string-search "state.focus===page.id?null:page" script))))

(ert-deftest org-museum-timeline-page-exposes-modal-filter-contract ()
  "The mobile filter sheet has a backdrop and modal semantics."
  (let* ((root (make-temp-file "org-museum-timeline-dialog-test-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (out-file (expand-file-name "exports/html/timeline.html" root))
         (html (org-museum--build-timeline-html
                out-file "{\"pages\":[],\"edges\":[]}" "resources/d3.min.js")))
    (unwind-protect
        (progn
          (should (string-search "timeline-filter-backdrop" html))
          (should (string-search "role=\"dialog\"" html))
          (should (string-search "aria-modal=\"false\"" html))
          (should (string-search "filterSheet.setAttribute('aria-modal',filterOpen?'true':'false')" html))
          (should (string-search "timeline-filter-result" html)))
      (delete-directory root t))))

(ert-deftest org-museum-timeline-runtime-keeps-navigation-boundaries ()
  "Previous, next, and same-day movement retain their edge guards."
  (let ((script (org-museum--script-timeline)))
    (dolist (needle '("previous.disabled=at<=0"
                      "next.disabled=at<0||at>=list.length-1"
                      "function navigateRelative(offset)"
                      "navigateRelative(-1)"
                      "navigateRelative(1)"
                      "function sameDateGroup(page,list)"
                      "item.createdDate===page.createdDate"))
      (should (string-search needle script)))))

(ert-deftest org-museum-timeline-runtime-restores-history-scroll-and-breakpoints ()
  "History and responsive changes preserve the reader's spatial anchor."
  (let ((script (org-museum--script-timeline)))
    (dolist (needle '("currentScroll=filterOpen&&filterScroll!==null?filterScroll:scrollY"
                      "history.replaceState({scrollY:currentScroll}"
                      "history.pushState({scrollY:currentScroll}"
                      "event.state&&Number.isFinite(event.state.scrollY)"
                      "lastViewportWidth=innerWidth"
                      "if(innerWidth===lastViewportWidth&&nextMobile===lastMobile)return"))
      (should (string-search needle script)))))

(ert-deftest org-museum-timeline-runtime-keeps-relation-and-isolation-noise-low ()
  "Only selected relations render and isolated notes obey active filters."
  (let ((script (org-museum--script-timeline)))
    (dolist (needle '("edge.source===page.id||edge.target===page.id"
                      ".classed('is-near'"
                      ".classed('is-muted'"
                      "visiblePages().filter(function(page){return relationCount(page)===0;})"))
      (should (string-search needle script)))))

(ert-deftest org-museum-timeline-page-is-offline-addressable-and-defensive ()
  "The timeline is a local, query-addressable page with mobile and keyboard paths."
  (let* ((root (make-temp-file "org-museum-timeline-page-test-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (out-file (expand-file-name "exports/html/timeline.html" root))
         (html (org-museum--build-timeline-html out-file "{\"pages\":[],\"edges\":[]}" "resources/d3.min.js")))
    (unwind-protect
        (progn
          (dolist (needle '("museum-timeline-shell" "timeline-mobile-list"
                            "timeline-scope-bar" "timeline-filter-sheet"
                            "timeline-focus-card" "timeline-previous"
                            "timeline-next" "timeline-return"
                            "q" "category" "status" "focus"
                            "ArrowLeft" "ArrowRight" "ArrowUp" "ArrowDown"
                            "同日更新" "筛选后已清除原选择"
                            "Date.parse(page.createdDate+'T00:00:00Z')"
                            "setFocus(next,true,true)"
                            "node.focus({preventScroll:true})"
                            ".classed('is-near'"
                            "visiblePages().filter(function(page){return relationCount(page)===0;})"
                            "selected&&!matches(selected)"
                            "edges.filter(function(edge)"
                            "if(!pageMap.has(state.focus))state.focus=''"
                            "window.addEventListener('popstate'"
                            "resources/d3.min.js"))
            (should (string-search needle html)))
          (should-not (string-search "class=\"timeline-preview\"" html))
          (should (string-search
                   "</section>\n    <aside id=\"timeline-focus-card\"" html))
          (should-not (string-search
                       "id=\"timeline-canvas\"><div id=\"timeline-svg\"></div><div id=\"timeline-tooltip\" role=\"tooltip\" hidden></div><aside" html))
          (should-not (string-match-p "\\bfetch[[:space:]]*(" html))
          (should (org-museum--publish-managed-relative-path-p "timeline.html"))
          (should (member "timeline.html"
                          (plist-get (org-museum--publish-default-policy)
                                     :include))))
      (delete-directory root t))))

(ert-deftest org-museum-related-summary-falls-back-to-exported-content ()
  (let ((page (org-museum-test--page "alpha" "Alpha" 1)))
    (cl-letf (((symbol-function 'org-museum--related-article-fragment)
              (lambda (_page)
                 "<p>:PROPERTIES: :ID: private :END:</p><p>首个有效段落。</p><p>第一节摘录。</p><p>第二节摘录。</p>"))
              ((symbol-function 'org-museum--related-rebase-fragment)
               (lambda (html _page _out-file) html))
              ((symbol-function 'org-museum--page-headings)
               (lambda (_page)
                 '(((id . "one") (title . "第一章") (level . 2))
                   ((id . "deep") (title . "细节") (level . 3)))))
              ((symbol-function 'org-museum--page-href)
               (lambda (&rest _args) "pages/alpha.html")))
      (let ((data (org-museum--related-page-alist page "related.html")))
        (should (equal "首个有效段落。" (alist-get 'description data)))
        (should (equal ["第一节摘录。" "第二节摘录。"]
                       (alist-get 'excerpts data)))
        (should (= 1 (length (alist-get 'headings data))))))))

(ert-deftest org-museum-related-full-content-localizes-generated-toc ()
  "Chinese relationship reading must not reintroduce Org's English TOC label."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-related-toc-test-" t)))
         (source (expand-file-name "pages/alpha.org" root))
         (page-file (expand-file-name "exports/html/pages/alpha.html" root))
         (out-file (expand-file-name "exports/html/related.html" root))
         (page (make-org-museum-page :id "alpha" :path source)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (with-temp-file source
            (insert "#+TITLE: Alpha\n#+LANGUAGE: zh-CN\n"))
          (cl-letf (((symbol-function 'org-museum--export-filename)
                     (lambda (_source) page-file)))
            (let ((result
                   (org-museum--related-rebase-fragment
                    (concat "<div id=\"table-of-contents\" role=\"doc-toc\">\n"
                            "<h2>Table of Contents</h2>\n"
                            "<div id=\"text-table-of-contents\"></div></div>")
                    page out-file)))
              (should (string-search "<h2>本文目录</h2>" result))
              (should-not (string-search "Table of Contents" result)))
            (with-temp-file source
              (insert "#+TITLE: Alpha\n#+LANGUAGE: en\n"))
            (let ((result
                   (org-museum--related-rebase-fragment
                    (concat "<div id=\"table-of-contents\" role=\"doc-toc\">\n"
                            "<h2>Table of Contents</h2>\n"
                            "<div id=\"text-table-of-contents\"></div></div>")
                    page out-file)))
              (should (string-search "<h2>Table of Contents</h2>" result))
              (should-not (string-search "本文目录" result)))))
      (delete-directory root t))))

(ert-deftest org-museum-related-rebase-preserves-link-match ()
  "Rebasing a relative URL must replace its HTML attribute exactly once."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-related-links-test-" t)))
         (source (expand-file-name "pages/alpha.org" root))
         (page-file (expand-file-name "exports/html/pages/alpha.html" root))
         (out-file (expand-file-name "exports/html/related.html" root))
         (page (make-org-museum-page :id "alpha" :path source)))
    (unwind-protect
        (cl-letf (((symbol-function 'org-museum--export-filename)
                   (lambda (_source) page-file)))
          (should
           (equal
            (concat "<a href=\"pages/next.html?topic=one#part\">Next</a>"
                    "<img src=\"pages/image.png\">"
                    "<a href=\"#related-alpha-local\">Here</a>")
            (org-museum--related-rebase-fragment
             (concat "<a href=\"next.html?topic=one#part\">Next</a>"
                     "<img src=\"image.png\">"
                     "<a href=\"#local\">Here</a>")
             page out-file))))
      (delete-directory root t))))

(ert-deftest org-museum-related-reader-is-offline-addressable-and-defensive ()
  (let* ((root (make-temp-file "org-museum-related-page-test-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/related.html" root))
         (data-file (expand-file-name
                     "exports/html/resources/org-museum-related-data.js" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory data-file) t)
          (with-temp-file data-file (insert "window.ORG_MUSEUM_RELATED_DATA={};"))
          (let ((html (org-museum--build-related-html out-file data-file)))
            (dolist (needle '("source" "target" "mode" "relationValid"
                              "显式 Org 链接" "data-related-panel=\"source\""
                              "data-related-panel=\"target\""))
              (should (string-search needle html)))
            (should-not (string-match-p "\\bfetch[[:space:]]*(" html))))
          (should (org-museum--publish-managed-relative-path-p "related.html"))
          (should (org-museum--publish-managed-relative-path-p
                   "resources/org-museum-related-data.js"))
          (should (member "related.html"
                          (plist-get (org-museum--publish-default-policy)
                                     :include))))
      (delete-directory root t)))

(ert-deftest org-museum-related-highlight-skips-unsupported-languages ()
  "Full relationship reading must not ask Highlight.js for unknown languages."
  (let ((script (org-museum--script-related-reading)))
    (should (string-search "className.indexOf('language-')===0" script))
    (should (string-search "hljs.getLanguage(lang)" script))
    (should (string-search "code.classList.add('no-highlight')" script))
    (should-not (string-search
                 "forEach(function(code){window.hljs.highlightElement(code);})"
                 script))))

(ert-deftest org-museum-theme-runtime-is-local-versioned-and-defensive ()
  "The blocking theme bootstrap is shared, offline, and rejects bad values."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-theme-runtime-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/index.html" root))
         (runtime (expand-file-name
                   "exports/html/resources/org-museum-theme.js" root)))
    (unwind-protect
        (let ((tag (org-museum--theme-script-tag out-file)))
          (should (file-exists-p runtime))
          (should (string-match-p
                   "org-museum-theme\\.js\\?v=[0-9a-f]\\{12\\}" tag))
          (should-not (string-match-p "defer" tag))
          (with-temp-buffer
            (insert-file-contents runtime)
            (dolist (needle '("org-museum-theme"
                              "value === \"light\" || value === \"dark\""
                              "document.documentElement.dataset.theme"
                              "new URL(href, location.href)"
                              "url.searchParams.set(key, currentTheme())"
                              "history.replaceState(history.state, \"\", url.href)"
                              "readThemeFromUrl"
                              "window.orgMuseumThemeUrl"
                              "data-theme-toggle"
                              "DOMContentLoaded"))
              (goto-char (point-min))
              (should (search-forward needle nil t)))
            (goto-char (point-min))
            (should (search-forward "data-theme-system" nil t))
            (goto-char (point-min))
            (should (search-forward "dataset.themePreference" nil t))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-sync-builds-a-managed-mirror ()
  "Publishing replaces managed output while preserving repository-owned files."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-sync-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (org-museum-test--unique-sibling-path root "published-site"))
         (export-root (expand-file-name "exports/html" root))
         (old-page (expand-file-name "pages/old.html"
                                     org-museum-publish-directory))
         (extra-file (expand-file-name "CNAME"
                                        org-museum-publish-directory))
         (readme (expand-file-name "README.md" org-museum-publish-directory))
         (git-config (expand-file-name ".git/config"
                                       org-museum-publish-directory)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages/topic" export-root) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (make-directory (file-name-directory old-page) t)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "INDEX"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (with-temp-file (expand-file-name "related.html" export-root)
            (insert "RELATED"))
          (with-temp-file (expand-file-name "timeline.html" export-root)
            (insert "TIMELINE"))
          (with-temp-file (expand-file-name "pages/topic/new.html" export-root)
            (insert "NEW"))
          (with-temp-file (expand-file-name "resources/site.js" export-root)
            (insert "SCRIPT"))
          (with-temp-file (expand-file-name ".org-museum-manifest.json"
                                            export-root)
            (insert "{\"pagesRoot\":\"C:/Users/private/wiki\"}"))
          (with-temp-file old-page (insert "OLD"))
          (with-temp-file extra-file (insert "notes.example"))
          (with-temp-file readme (insert "Repository notes"))
          (make-directory (file-name-directory git-config) t)
          (with-temp-file git-config (insert "[core]"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json"
                                org-museum-publish-directory)
            (insert "{\"schemaVersion\":1,\"files\":[\"pages/old.html\"]}"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore))
            (org-museum-publish-sync)
            (org-museum-publish-sync))
          (should-not (file-exists-p old-page))
          (should (equal (org-museum-test--file-string extra-file)
                         "notes.example"))
          (should (equal (org-museum-test--file-string readme)
                         "Repository notes"))
          (should (equal (org-museum-test--file-string git-config) "[core]"))
          (should (equal
                   (org-museum-test--file-string
                    (expand-file-name "pages/topic/new.html"
                                      org-museum-publish-directory))
                   "NEW"))
          (should (file-exists-p
                   (expand-file-name ".nojekyll"
                                     org-museum-publish-directory)))
          (should-not
           (file-exists-p
            (expand-file-name ".org-museum-manifest.json"
                              org-museum-publish-directory)))
          (let ((manifest
                 (org-museum-test--file-string
                  (expand-file-name ".org-museum-publish-manifest.json"
                                    org-museum-publish-directory))))
            (should (string-match-p "pages/topic/new\\.html" manifest))
            (should-not (string-match-p "[A-Za-z]:[/\\\\]" manifest))))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t)))))

(ert-deftest org-museum-publish-deploy-refuses-unmanaged-dirty-files ()
  "Deployment never stages or pushes repository-owned work."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-git-test-" t)))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         (org-museum-publish-branch "main")
         (org-museum-publish-remote "origin")
         (default-directory root))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" root)
            (insert "ORIGINAL"))
          (with-temp-file (expand-file-name ".nojekyll" root))
          (with-temp-file
              (expand-file-name ".org-museum-publish-status.json" root)
            (insert "{\"schemaVersion\":1,\"state\":\"ready\","
                    "\"blockedPages\":[]}"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert "{\"schemaVersion\":1,"
                    "\"files\":[\".nojekyll\","
                    "\".org-museum-publish-status.json\",\"index.html\"]}"))
          (should (= 0 (call-process "git" nil nil nil "init" "-b" "main")))
          (should (= 0 (call-process "git" nil nil nil "add" "--all" "--")))
          (should (= 0 (call-process "git" nil nil nil
                                     "commit" "-m" "Initial publish")))
          (with-temp-file (expand-file-name "index.html" root)
            (insert "UPDATED"))
          (with-temp-file (expand-file-name "private-notes.txt" root)
            (insert "DO NOT PUBLISH"))
          (let ((error-data
                 (should-error (org-museum-publish-deploy)
                               :type 'org-museum-publish-error)))
            (should (string-match-p "private-notes\\.txt"
                                    (error-message-string error-data))))
          (should-not
           (string-match-p "private-notes\\.txt"
                           (with-temp-buffer
                             (call-process "git" nil t nil
                                           "diff" "--cached" "--name-only")
                             (buffer-string)))))
      (delete-directory root t))))

(ert-deftest org-museum-interactive-export-and-publish-commands-run-in-background ()
  "Every user-facing export and publish command delegates to one background job."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-background-command-test-" t)))
         (source (expand-file-name "page.org" root))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         calls)
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root) t)
          (with-temp-file source (insert "#+TITLE: Page\n"))
          (cl-letf (((symbol-function 'org-museum--start-background-job)
                     (lambda (action args)
                       (push (list action args) calls)
                       'background-process))
                    ((symbol-function 'called-interactively-p)
                     (lambda (_kind) t))
                    ((symbol-function 'read-string)
                     (lambda (&rest _) org-museum--publish-full-confirmation)))
            (with-temp-buffer
              (setq buffer-file-name source)
              (should (eq (call-interactively #'org-museum-export-page)
                          'background-process)))
            (should (eq (call-interactively #'org-museum-export-all)
                        'background-process))
            (should (eq (call-interactively #'org-museum-export-graph)
                        'background-process))
            (should (eq (call-interactively #'org-museum-export-related-reading)
                        'background-process))
            (should (eq (call-interactively #'org-museum-export-timeline)
                        'background-process))
            (should (eq (call-interactively #'org-museum-publish-sync)
                        'background-process))
            (should (eq (call-interactively #'org-museum-publish-sync-full)
                        'background-process))
            (should (eq (call-interactively #'org-museum-publish-deploy)
                        'background-process)))
          (should
           (equal (sort (mapcar #'car calls)
                        (lambda (left right)
                          (string< (symbol-name left) (symbol-name right))))
                  '(export-all export-graph export-page export-related-reading
                    export-timeline publish-deploy publish-sync
                    publish-sync-full))))
      (delete-directory root t))))

(ert-deftest org-museum-background-script-quotes-symbol-and-list-options ()
  "Worker configuration is emitted as data rather than evaluated variables."
  (let ((org-museum-curation-mode 'protocol)
        (org-museum-open-page-after-export 'index)
        (org-museum-graph-exclude-tags '("no-graph" "private")))
    (let ((script (org-museum--background-script
                   "C:/org-museum.el" 'export-all nil)))
      (should (string-match-p
               (regexp-quote
                "org-museum-curation-mode (quote protocol)")
               script))
      (should (string-match-p
               (regexp-quote
                "org-museum-open-page-after-export (quote index)")
               script))
      (should (string-match-p
               (regexp-quote
                "org-museum-graph-exclude-tags (quote (\"no-graph\" \"private\"))")
               script)))))

(ert-deftest org-museum-background-success-actions-open-requested-results ()
  "Successful full export and publish sync retain their user-visible outcomes."
  (let ((org-museum-root-dir "C:/wiki/")
        (org-museum-shared-export-dir "exports/html")
        (org-museum-open-browser-after-export t)
        (org-museum-open-page-after-export 'index)
        (org-museum-publish-directory "C:/published/")
        (org-museum-open-publish-directory-after-sync t))
    (should
     (equal (org-museum--background-success-action 'export-all)
            '(browse-url . "file:///c:/wiki/exports/html/index.html")))
    (should
     (equal (org-museum--background-success-action 'publish-sync)
            '(open-directory . "c:/published/")))))

(ert-deftest org-museum-background-sentinel-opens-results-only-after-success ()
  "Failed jobs never open stale export or publish results."
  (let ((org-museum--background-process 'fixture-process)
        opened
        (status 'exit)
        (exit-status 0))
    (cl-letf (((symbol-function 'process-status) (lambda (_process) status))
              ((symbol-function 'process-exit-status)
               (lambda (_process) exit-status))
              ((symbol-function 'process-get)
               (lambda (_process property)
                 (pcase property
                   ('org-museum-script nil)
                   ('org-museum-action 'export-all)
                   ('org-museum-success-action
                    '(browse-url . "file:///C:/wiki/index.html")))))
              ((symbol-function 'org-museum--open-background-success-action)
               (lambda (action) (setq opened action)))
              ((symbol-function 'display-warning) #'ignore))
      (org-museum--background-sentinel 'fixture-process "finished")
      (should (equal opened '(browse-url . "file:///C:/wiki/index.html")))
      (setq opened nil
            org-museum--background-process 'fixture-process
            exit-status 1)
      (org-museum--background-sentinel 'fixture-process "failed")
      (should-not opened))))

(ert-deftest org-museum-background-emacs-resolves-windows-versioned-executable ()
  "A daemon invocation name without .exe resolves to its real Windows binary."
  (let ((org-museum-background-emacs-program nil)
        (invocation-directory "C:/v/Emacs/bin/")
        (invocation-name "emacs-31.1"))
    (cl-letf (((symbol-function 'file-executable-p)
               (lambda (path)
                 (equal (downcase
                         (replace-regexp-in-string "\\\\" "/" path))
                        "c:/v/emacs/bin/emacs-31.1.exe")))
              ((symbol-function 'executable-find) (lambda (_name) nil)))
      (should
       (equal (org-museum--background-emacs-executable)
              "c:/v/Emacs/bin/emacs-31.1.exe")))))

(ert-deftest org-museum-publish-deploy-refuses-a-blocked-preview-first ()
  "A blocked privacy status stops deployment before Git or GitHub runs."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-blocked-deploy-" t)))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         (org-museum-publish-branch "main")
         (org-museum-publish-remote "origin")
         process-called)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" root)
            (insert "SAFE PREVIEW"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-status.json" root)
            (insert "{\"schemaVersion\":1,\"state\":\"blocked\","
                    "\"blockedPages\":[\"pages/private.html\"]}"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert "{\"schemaVersion\":1,\"files\":["
                    "\".org-museum-publish-status.json\",\"index.html\"]}"))
          (cl-letf (((symbol-function 'org-museum--publish-run)
                     (lambda (&rest _args)
                       (setq process-called t)
                       (cons 0 ""))))
            (let ((error-data
                   (should-error (org-museum-publish-deploy)
                                 :type 'org-museum-publish-error)))
              (should (string-match-p "隐私检查"
                                      (error-message-string error-data)))))
          (should-not process-called))
      (delete-directory root t))))

(ert-deftest org-museum-publish-deploy-revalidates-a-ready-candidate ()
  "A mutable ready status cannot authorize unsafe or placeholder content."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-ready-recheck-" t)))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         (org-museum-publish-branch "main")
         (org-museum-publish-remote "origin")
         process-called)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" root) t)
          (with-temp-file (expand-file-name "index.html" root)
            (insert "INDEX"))
          (with-temp-file (expand-file-name "pages/private.html" root)
            (insert "<meta name=\"org-museum-privacy-placeholder\" "
                    "content=\"blocked\">"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-status.json" root)
            (insert "{\"schemaVersion\":1,\"state\":\"ready\","
                    "\"blockedPages\":[]}"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert "{\"schemaVersion\":1,\"files\":["
                    "\".org-museum-publish-status.json\",\"index.html\","
                    "\"pages/private.html\"]}"))
          (cl-letf (((symbol-function 'org-museum--publish-run)
                     (lambda (&rest _args)
                       (setq process-called t)
                       (cons 0 ""))))
            (let ((error-data
                   (should-error (org-museum-publish-deploy)
                                 :type 'org-museum-publish-error)))
              (should (string-match-p "placeholder"
                                      (error-message-string error-data))))
            (with-temp-file (expand-file-name "pages/private.html" root)
              (insert "<code>C:/private/secret.txt</code>"))
            (let ((error-data
                   (should-error (org-museum-publish-deploy)
                                 :type 'org-museum-publish-error)))
              (should (string-match-p "local paths"
                                      (error-message-string error-data))))
            ;; Removing the unsafe managed page from the mutable manifest must
            ;; not make the existing checkout eligible for deployment.
            (with-temp-file
                (expand-file-name ".org-museum-publish-manifest.json" root)
              (insert "{\"schemaVersion\":1,\"files\":["
                      "\".org-museum-publish-status.json\",\"index.html\"]}"))
            (let ((error-data
                   (should-error (org-museum-publish-deploy)
                                 :type 'org-museum-publish-error)))
              (should (string-match-p "manifest"
                                      (error-message-string error-data)))))
          (should-not process-called))
      (delete-directory root t))))

(ert-deftest org-museum-publish-deploy-requires-a-current-status-file ()
  "An older mirror must be resynchronised before any deployment process runs."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-missing-status-" t)))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         process-called)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" root) (insert "INDEX"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert "{\"schemaVersion\":1,\"files\":[\"index.html\"]}"))
          (cl-letf (((symbol-function 'org-museum--publish-run)
                     (lambda (&rest _args)
                       (setq process-called t)
                       (cons 0 ""))))
            (let ((error-data
                   (should-error (org-museum-publish-deploy)
                                 :type 'org-museum-publish-error)))
              (should (string-match-p "status is missing"
                                      (error-message-string error-data)))))
          (should-not process-called))
      (delete-directory root t))))

(ert-deftest org-museum-publish-sync-builds-safe-preview-for-private-pages ()
  "A private page becomes a safe preview placeholder with a local report."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-private-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-publish-directory
          (org-museum-test--unique-sibling-path root "private-publish-site"))
         (export-root (expand-file-name "exports/html" root))
         (source (expand-file-name "pages/private.org" root))
         (page-output (expand-file-name "pages/private.html" export-root))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" export-root) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (make-directory (file-name-directory source) t)
          (with-temp-file source
            (insert "#+TITLE: Private\n"
                    "Local example: C:/private/secret.txt\n"))
          (puthash "private"
                   (org-museum-test--page
                    "private" "Private" 1 nil nil "published" source)
                   pages)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "INDEX"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (with-temp-file (expand-file-name "related.html" export-root)
            (insert "RELATED"))
          (with-temp-file (expand-file-name "timeline.html" export-root)
            (insert "TIMELINE"))
          (with-temp-file page-output
            (insert "<code>path:C:/private/secret.txt</code>"))
          (with-temp-file (expand-file-name "resources/private.js" export-root)
            (insert "source:C:/private/app.js"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore))
            (should-not (org-museum-publish-sync)))
          (should (file-directory-p org-museum-publish-directory))
          (let ((preview
                 (org-museum-test--file-string
                  (expand-file-name "pages/private.html"
                                    org-museum-publish-directory)))
                (status
                 (org-museum-test--file-string
                  (expand-file-name ".org-museum-publish-status.json"
                                    org-museum-publish-directory)))
                (manifest
                 (org-museum-test--file-string
                  (expand-file-name ".org-museum-publish-manifest.json"
                                    org-museum-publish-directory))))
            (should (string-match-p "公开检查" preview))
            (should-not (string-match-p "C:/private" preview))
            (should (string-match-p "\\\"state\\\":\\\"blocked\\\"" status))
            (should (string-match-p "pages/private\\.html" status))
            (should (string-match-p "resources/private\\.js" status))
            (should-not (string-match-p "[A-Za-z]:[/\\\\]" status))
            (should (string-match-p
                     "\\.org-museum-publish-status\\.json" manifest)))
          (should-not
           (file-exists-p
            (expand-file-name "resources/private.js"
                              org-museum-publish-directory)))
          (with-current-buffer "*Org Museum 隐私报告*"
            (should (derived-mode-p 'special-mode))
            (should (string-match-p "private\\.org:2" (buffer-string)))
            (should (string-match-p "C:/private/secret\\.txt"
                                    (buffer-string)))
            (let ((rerun-called nil))
              (cl-letf (((symbol-function 'org-museum-publish-sync)
                         (lambda () (interactive) (setq rerun-called t))))
                (button-activate (button-at (point-min))))
              (should rerun-called))
            (let* ((position
                    (text-property-any (point-min) (point-max)
                                       'org-museum-source source))
                   (source-button (and position (button-at position))))
              (should source-button)
              (button-activate source-button)))
          (let ((source-buffer (get-file-buffer source)))
            (should source-buffer)
            (with-current-buffer source-buffer
              (should (= 2 (line-number-at-pos))))
            (kill-buffer source-buffer))
          (with-temp-file source
            (insert "#+TITLE: Private\nPortable example\n"))
          (with-temp-file page-output
            (insert "PUBLIC PAGE"))
          (with-temp-file (expand-file-name "resources/private.js" export-root)
            (insert "PUBLIC SCRIPT"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore))
            (should (equal (org-museum-publish-sync)
                           (file-name-as-directory
                            (expand-file-name org-museum-publish-directory)))))
          (should (equal
                   (org-museum-test--file-string
                    (expand-file-name "pages/private.html"
                                      org-museum-publish-directory))
                   "PUBLIC PAGE"))
          (should (equal
                   (org-museum-test--file-string
                    (expand-file-name "resources/private.js"
                                      org-museum-publish-directory))
                   "PUBLIC SCRIPT"))
          (should (string-match-p
                   "\\\"state\\\":\\\"ready\\\""
                   (org-museum-test--file-string
                    (expand-file-name ".org-museum-publish-status.json"
                                      org-museum-publish-directory))))
          (with-current-buffer "*Org Museum 隐私报告*"
            (should (string-match-p "未发现隐私材料" (buffer-string)))))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t))
      (when (get-buffer "*Org Museum 隐私报告*")
        (kill-buffer "*Org Museum 隐私报告*")))))

(ert-deftest org-museum-publish-full-sync-copies-unresolved-content-for-review ()
  "Full sync keeps raw selected bytes locally but does not make them deployable."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-full-test-" t)))
         (user-emacs-directory root)
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (org-museum-test--unique-sibling-path root "full-publish"))
         (org-museum-publish-policy-file
          (expand-file-name "org-museum-publish-policy.json" root))
         (export-root (expand-file-name "exports/html" root))
         (source (expand-file-name "pages/private.org" root))
         (page-output (expand-file-name "pages/private.html" export-root))
         (resource-output (expand-file-name "resources/private.js" export-root))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (make-directory (file-name-directory page-output) t)
          (make-directory (file-name-directory resource-output) t)
          (with-temp-file source
            (insert "#+TITLE: Private\nPath C:/private/note.org\n"))
          (puthash "private"
                   (org-museum-test--page
                    "private" "Private" 1 nil nil "published" source)
                   pages)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "INDEX"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (with-temp-file (expand-file-name "related.html" export-root)
            (insert "RELATED"))
          (with-temp-file (expand-file-name "timeline.html" export-root)
            (insert "TIMELINE"))
          (with-temp-file page-output
            (insert "<code>C:/private/note.org</code>"))
          (with-temp-file resource-output
            (insert "const local = 'C:/private/app.js';"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args) "COPY PRIVATE EXPORTS"))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (call-interactively #'org-museum-publish-sync-full))
          (should (equal
                   (org-museum-test--file-string
                    (expand-file-name "pages/private.html"
                                      org-museum-publish-directory))
                   "<code>C:/private/note.org</code>"))
          (should (equal
                   (org-museum-test--file-string
                    (expand-file-name "resources/private.js"
                                      org-museum-publish-directory))
                   "const local = 'C:/private/app.js';"))
          (let ((status
                 (org-museum-test--file-string
                  (expand-file-name ".org-museum-publish-status.json"
                                    org-museum-publish-directory))))
            (should (string-match-p
                     "\"state\":\"review-required\"" status)))
          (should (get-buffer "*Org Museum 完整同步预览*"))
          (with-current-buffer "*Org Museum 完整同步预览*"
            (let ((position (point-min)) buttons)
              (while (setq position
                           (text-property-any
                            position (point-max)
                            'org-museum-policy-action 'authorize))
                (push (button-at position) buttons)
                (setq position
                      (or (next-single-property-change
                           position 'org-museum-policy-action nil (point-max))
                          (point-max))))
              (should (= 2 (length buttons)))
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _args) "Approved public example")))
                (dolist (button buttons) (button-activate button)))))
          (let ((policy-text
                 (org-museum-test--file-string
                  org-museum-publish-policy-file)))
            (should (string-match-p "authorizations" policy-text))
            (should-not (string-match-p "C:/private" policy-text)))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args) "COPY PRIVATE EXPORTS"))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (call-interactively #'org-museum-publish-sync-full))
          (should (string-match-p
                   "\"state\":\"ready\""
                   (org-museum-test--file-string
                    (expand-file-name ".org-museum-publish-status.json"
                                      org-museum-publish-directory))))
          (let ((manifest
                 (org-museum--publish-read-manifest
                  org-museum-publish-directory))
                (status
                 (org-museum--publish-read-status
                  org-museum-publish-directory)))
            (org-museum--publish-validate-manifest-integrity
             org-museum-publish-directory manifest)
            (org-museum--publish-validate-full-ready-candidate
             org-museum-publish-directory manifest status))
          (with-temp-file resource-output
            (insert "const local = 'C:/private/changed.js';"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args) "COPY PRIVATE EXPORTS"))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (call-interactively #'org-museum-publish-sync-full))
          (should (string-match-p
                   "\"state\":\"review-required\""
                   (org-museum-test--file-string
                    (expand-file-name ".org-museum-publish-status.json"
                                      org-museum-publish-directory))))
          (with-current-buffer "*Org Museum 完整同步预览*"
            (let ((position (point-min)) target)
              (while (and (not target)
                          (setq position
                                (text-property-any
                                 position (point-max)
                                 'org-museum-policy-action 'exclude)))
                (let ((button (button-at position)))
                  (if (equal (button-get button 'org-museum-relative)
                             "resources/private.js")
                      (setq target button)
                    (setq position
                          (or (next-single-property-change
                               position 'org-museum-policy-action nil
                               (point-max))
                              (point-max))))))
              (should target)
              (button-activate target)))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args) "COPY PRIVATE EXPORTS"))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (call-interactively #'org-museum-publish-sync-full))
          (should-not (file-exists-p
                       (expand-file-name "resources/private.js"
                                         org-museum-publish-directory)))
          (should (string-match-p
                   "\"state\":\"ready\""
                   (org-museum-test--file-string
                    (expand-file-name ".org-museum-publish-status.json"
                                      org-museum-publish-directory))))
          (should-not (lookup-key org-museum-mode-map (kbd "C-c w !"))))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t))
      (when (get-buffer "*Org Museum 完整同步预览*")
        (kill-buffer "*Org Museum 完整同步预览*")))))

(ert-deftest org-museum-publish-full-sync-refuses-managed-file-conflicts ()
  "A full sync records hashes and never overwrites a post-sync manual edit."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-full-conflict-" t)))
         (user-emacs-directory root)
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (org-museum-test--unique-sibling-path root "full-conflict"))
         (org-museum-publish-policy-file
          (expand-file-name "org-museum-publish-policy.json" root))
         (export-root (expand-file-name "exports/html" root))
         (source-page (expand-file-name "pages/topic.html" export-root))
         (published-page
          (expand-file-name "pages/topic.html" org-museum-publish-directory)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source-page) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "INDEX"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (with-temp-file (expand-file-name "related.html" export-root)
            (insert "RELATED"))
          (with-temp-file (expand-file-name "timeline.html" export-root)
            (insert "TIMELINE"))
          (with-temp-file source-page (insert "VERSION ONE"))
          (with-temp-file (expand-file-name "resources/site.css" export-root)
            (insert "CSS"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args) "COPY PRIVATE EXPORTS"))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (call-interactively #'org-museum-publish-sync-full))
          (let ((manifest
                 (org-museum-test--file-string
                  (expand-file-name ".org-museum-publish-manifest.json"
                                    org-museum-publish-directory))))
            (should (string-match-p "\"schemaVersion\":2" manifest))
            (should (string-match-p "\"sha256\"" manifest))
            (should (string-match-p
                     "[[:xdigit:]]\\{64\\}" manifest))
            (should-not (string-match-p "VERSION ONE" manifest)))
          (with-temp-file published-page (insert "LOCAL MANUAL EDIT"))
          (with-temp-file source-page (insert "VERSION TWO"))
          (let ((confirmation-called nil))
            (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                      ((symbol-function 'read-string)
                       (lambda (&rest _args)
                         (setq confirmation-called t)
                         "COPY PRIVATE EXPORTS"))
                      ((symbol-function 'pop-to-buffer) #'ignore))
              (should-error
               (call-interactively #'org-museum-publish-sync-full)
               :type 'org-museum-publish-error))
            (should-not confirmation-called))
          (should (equal (org-museum-test--file-string published-page)
                         "LOCAL MANUAL EDIT")))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t))
      (when (get-buffer "*Org Museum 完整同步预览*")
        (kill-buffer "*Org Museum 完整同步预览*")))))

(ert-deftest org-museum-publish-full-deploy-rejects-policy-drift-before-processes ()
  "Changing the local sharing policy invalidates a ready full-sync review."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-policy-drift-" t)))
         (user-emacs-directory root)
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (org-museum-test--unique-sibling-path root "policy-drift"))
         (org-museum-publish-policy-file
          (expand-file-name "org-museum-publish-policy.json" root))
         (org-museum-publish-repository "owner/notes")
         (org-museum-publish-branch "main")
         (org-museum-publish-remote "origin")
         (export-root (expand-file-name "exports/html" root))
         (process-called nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" export-root) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (dolist (entry '(("index.html" . "INDEX")
                           ("timeline.html" . "TIMELINE")
                           ("graph.html" . "GRAPH")
                           ("related.html" . "RELATED")
                           ("pages/topic.html" . "TOPIC")
                           ("resources/site.css" . "CSS")))
            (with-temp-file (expand-file-name (car entry) export-root)
              (insert (cdr entry))))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args) "COPY PRIVATE EXPORTS"))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (call-interactively #'org-museum-publish-sync-full))
          (let ((policy (org-museum--publish-default-policy)))
            (setf (plist-get policy :exclude) '("pages/unused.html"))
            (org-museum--publish-write-policy policy))
          (cl-letf (((symbol-function 'org-museum--publish-run)
                     (lambda (&rest _args)
                       (setq process-called t)
                       (cons 0 ""))))
            (should-error (org-museum-publish-deploy)
                          :type 'org-museum-publish-error))
          (should-not process-called))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t))
      (when (get-buffer "*Org Museum 完整同步预览*")
        (kill-buffer "*Org Museum 完整同步预览*")))))

(ert-deftest org-museum-publish-policy-supports-scope-and-custom-detectors ()
  "Policy globs select scope and supplemental rules produce named findings."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-custom-detector-" t)))
         (org-museum-publish-policy-file (expand-file-name "policy.json" root))
         (file (expand-file-name "pages/topic.html" root))
         (policy
          (list :include '("pages/**" "resources/**")
                :exclude '("pages/private/**")
                :authorizations nil
                :detectors
                '(((name . "account marker")
                   (regexp . "ACCOUNT-[[:digit:]]+")
                   (group . 0)
                   (suggestion . "Replace it with a public example."))))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "ACCOUNT-42"))
          (org-museum--publish-write-policy policy)
          (let ((read-policy (org-museum--publish-read-policy)))
            (should (org-museum--publish-policy-selected-p
                     read-policy "pages/topic.html"))
            (should-not (org-museum--publish-policy-selected-p
                         read-policy "pages/private/topic.html"))
            (let ((findings
                   (org-museum--publish-privacy-findings
                    (list file) root (plist-get read-policy :detectors))))
              (should (= 1 (length findings)))
              (should (eq 'custom-account-marker
                          (org-museum-publish-finding-kind (car findings))))
              (should (equal "Replace it with a public example."
                             (org-museum-publish-finding-suggestion
                              (car findings)))))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-safety-refusal-is-a-user-error ()
  "An expected privacy refusal must not enter the debugger."
  (should (memq 'user-error
                (get 'org-museum-publish-error 'error-conditions))))

(ert-deftest org-museum-publish-report-locates-every-source-reference ()
  "The local report maps direct and relative-file findings to source lines."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-report-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-export-dir "exports/html/pages")
         (source (expand-file-name "pages/topic.org" root))
         (output (expand-file-name "exports/html/pages/topic.html" root))
         (external (expand-file-name "A&B outside.sql" root))
         (pages (make-hash-table :test 'equal))
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (make-directory (file-name-directory output) t)
          (with-temp-file source
            (insert "#+TITLE: Topic\n"
                    "Code path: C:/private/code.el\n"
                    "[[file:../A&B outside.sql][Query]]\n"
                    "Repeated path: C:/private/code.el\n"))
          (puthash "topic"
                   (org-museum-test--page
                    "topic" "Topic" 1 nil nil "published" source)
                   pages)
          (with-temp-file output
            (insert "<code>C:/private/code.el</code>\n"
                    (format
                     (concat "<a href=\"file:///%s\" "
                             "data-local-path=\"%s\">Query</a>\n")
                     (replace-regexp-in-string
                      "&" "&amp;"
                      (replace-regexp-in-string "\\\\" "/" external) t t)
                     (replace-regexp-in-string
                      "&" "&amp;"
                      (replace-regexp-in-string "\\\\" "/" external) t t))
                    "<code>C:/private/code.el</code>\n"))
          (let ((findings
                 (org-museum--publish-privacy-findings
                  (list output) (expand-file-name "exports/html" root))))
            (should (= 3 (length findings)))
            (should (equal '(2 3 4)
                           (sort (mapcar #'org-museum-publish-finding-line
                                         findings)
                                 #'<)))
            (let ((kinds (mapcar #'org-museum-publish-finding-kind findings)))
              (should (memq 'absolute-path kinds))
              (should (memq 'local-file-link kinds)))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-privacy-scan-distinguishes-unc-from-javascript ()
  "UNC paths are private, while bundled regular-expression syntax is safe."
  (let ((unc-file (make-temp-file "org-museum-publish-unc-" nil ".js"))
        (unc-url-file (make-temp-file "org-museum-publish-unc-url-" nil ".html"))
        (unc-authority-file
         (make-temp-file "org-museum-publish-unc-authority-" nil ".html"))
        (drive-file (make-temp-file "org-museum-publish-drive-" nil ".js"))
        (public-url-file
         (make-temp-file "org-museum-publish-public-url-" nil ".html"))
        (syntax-file (make-temp-file "org-museum-publish-js-" nil ".js")))
    (unwind-protect
        (progn
          (with-temp-file unc-file (insert "open('\\\\server\\share\\note.org')"))
          (with-temp-file unc-url-file
            (insert "<a href=\"file:////server/share/note.org\" "
                    "data-local-path=\"//server/share/note.org\">Local</a>"))
          (with-temp-file unc-authority-file
            (insert "<a href=\"file://server/share/A&amp;B note.org\">"
                    "Authority UNC</a>"))
          (with-temp-file drive-file (insert "source:C:/$private/secret.txt"))
          (with-temp-file public-url-file
            (insert "<script src=\"//cdn.example.com/app.js\"></script>"))
          (with-temp-file syntax-file
            (insert "\\\\\\*{2}[^\\n]*? begin:/HTTP\\\\/ ?o:/[%p]"))
          (should (equal (org-museum--publish-privacy-violations
                          (list unc-file unc-url-file unc-authority-file
                                drive-file public-url-file syntax-file))
                         (list unc-file unc-url-file unc-authority-file
                               drive-file))))
      (delete-file unc-file)
      (delete-file unc-url-file)
      (delete-file unc-authority-file)
      (delete-file drive-file)
      (delete-file public-url-file)
      (delete-file syntax-file))))

(ert-deftest org-museum-publish-normalizes-org-html-windows-file-urls ()
  "Org HTML's drive prefix must not duplicate an encoded Windows drive."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-file-url-" t)))
         (source (expand-file-name "pages/vibe/note.org" root))
         (output (expand-file-name "exports/html/pages/vibe/note.html" root))
         (pages (make-hash-table :test 'equal))
         (org-museum-root-dir root)
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "exports/html/pages")
         (org-museum-shared-export-dir "exports/html")
         (org-museum--index
          (make-org-museum-index
           :pages pages
           :tags (make-hash-table :test 'equal)
           :categories (make-hash-table :test 'equal)
           :graph (make-hash-table :test 'equal))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory source) t)
          (make-directory (file-name-directory output) t)
          (with-temp-file source
            (insert "#+TITLE: Note\n"
                    "[workflow](recipe;file:///c%3A/Users/example/workflow.md)\n"))
          (puthash "note"
                   (org-museum-test--page
                    "note" "Note" 1 nil nil "published" source)
                   pages)
          (with-temp-buffer
            ;; This is the malformed URL emitted by Org HTML on Windows when
            ;; the source file URL contains a percent-encoded drive colon.
            (insert "<a href=\"file:///c:/c%3A/Users/example/workflow.md\">"
                    "file:///c:/c%3A/Users/example/workflow.md</a>")
            (org-museum--pp-annotate-local-file-links)
            (write-region (point-min) (point-max) output nil 'silent))
          (let ((findings
                 (org-museum--publish-privacy-findings
                  (list output) (expand-file-name "exports/html" root))))
            (should (= 1 (length findings)))
            (should (equal "c:/Users/example/workflow.md"
                           (org-museum-publish-finding-match (car findings))))
            (should (eq 'local-file-link
                        (org-museum-publish-finding-kind (car findings))))
            (should (= 2 (org-museum-publish-finding-line (car findings))))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-sync-keeps-old-mirror-on-preview-build-failure ()
  "Placeholder and status failures occur before the old mirror is installed."
  (dolist (failure-function '(org-museum--publish-write-placeholder
                              org-museum--publish-write-status))
    (let* ((root (file-name-as-directory
                  (make-temp-file "org-museum-preview-build-failure-" t)))
           (org-museum-root-dir root)
           (org-museum-shared-export-dir "exports/html")
           (org-museum-publish-directory
            (org-museum-test--unique-sibling-path root "publish"))
           (export-root (expand-file-name "exports/html" root))
           (source (expand-file-name "pages/private.org" root))
           (pages (make-hash-table :test 'equal))
           (org-museum--index
            (make-org-museum-index
             :pages pages
             :tags (make-hash-table :test 'equal)
             :categories (make-hash-table :test 'equal)
             :graph (make-hash-table :test 'equal))))
      (unwind-protect
          (progn
            (make-directory (expand-file-name "pages" export-root) t)
            (make-directory (expand-file-name "resources" export-root) t)
            (make-directory (file-name-directory source) t)
            (make-directory org-museum-publish-directory t)
            (with-temp-file source (insert "Local C:/private/secret.txt\n"))
            (puthash "private"
                     (org-museum-test--page
                      "private" "Private" 1 nil nil "published" source)
                     pages)
            (with-temp-file (expand-file-name "index.html" export-root)
              (insert "NEW INDEX"))
            (with-temp-file (expand-file-name "graph.html" export-root)
              (insert "GRAPH"))
            (with-temp-file (expand-file-name "related.html" export-root)
              (insert "RELATED"))
            (with-temp-file (expand-file-name "timeline.html" export-root)
              (insert "TIMELINE"))
            (with-temp-file (expand-file-name "pages/private.html" export-root)
              (insert "<code>C:/private/secret.txt</code>"))
            (with-temp-file (expand-file-name "index.html"
                                              org-museum-publish-directory)
              (insert "OLD INDEX"))
            (with-temp-file
                (expand-file-name ".org-museum-publish-manifest.json"
                                  org-museum-publish-directory)
              (insert "{\"schemaVersion\":1,\"files\":[\"index.html\"]}"))
            (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                      ((symbol-function failure-function)
                       (lambda (&rest _args) (error "fixture build failure"))))
              (should-error (org-museum-publish-sync)))
            (should (equal
                     (org-museum-test--file-string
                      (expand-file-name "index.html"
                                        org-museum-publish-directory))
                     "OLD INDEX"))
            (should-not
             (file-exists-p
              (expand-file-name ".org-museum-publish-status.json"
                                org-museum-publish-directory))))
        (delete-directory root t)
        (when (file-directory-p org-museum-publish-directory)
          (delete-directory org-museum-publish-directory t))))))

(ert-deftest org-museum-publish-sync-keeps-old-mirror-on-staging-copy-failure ()
  "A partial temporary candidate copy never reaches the existing mirror."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-staging-copy-failure-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (org-museum-test--unique-sibling-path root "publish"))
         (export-root (expand-file-name "exports/html" root))
         (original-copy-file (symbol-function 'copy-file))
         (copy-count 0))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" export-root) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (make-directory org-museum-publish-directory t)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "NEW INDEX"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (with-temp-file (expand-file-name "related.html" export-root)
            (insert "RELATED"))
          (with-temp-file (expand-file-name "timeline.html" export-root)
            (insert "TIMELINE"))
          (with-temp-file (expand-file-name "timeline.html" export-root)
            (insert "TIMELINE"))
          (with-temp-file (expand-file-name "index.html"
                                            org-museum-publish-directory)
            (insert "OLD INDEX"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json"
                                org-museum-publish-directory)
            (insert "{\"schemaVersion\":1,\"files\":[\"index.html\"]}"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'copy-file)
                     (lambda (source destination &rest args)
                       (if (and (file-in-directory-p source export-root)
                                (= (cl-incf copy-count) 2))
                           (error "fixture staging copy failure")
                         (apply original-copy-file source destination args)))))
            (should-error (org-museum-publish-sync)))
          (should (equal
                   (org-museum-test--file-string
                    (expand-file-name "index.html"
                                      org-museum-publish-directory))
                   "OLD INDEX"))
          (should-not
           (file-exists-p
            (expand-file-name ".org-museum-publish-status.json"
                              org-museum-publish-directory))))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t)))))

(ert-deftest org-museum-publish-rejects-a-linked-export-tree-root ()
  "The pages/resources roots themselves cannot redirect the source walk."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-source-link-test-" t)))
         (pages (expand-file-name "pages" root))
         (original-link (symbol-function 'file-symlink-p)))
    (unwind-protect
        (progn
          (make-directory pages t)
          (cl-letf (((symbol-function 'file-symlink-p)
                     (lambda (path)
                       (if (equal (expand-file-name path) pages)
                           "outside"
                         (funcall original-link path)))))
            (should-error (org-museum--publish-tree-files root "pages")
                          :type 'org-museum-publish-error)))
      (delete-directory root t))))

(ert-deftest org-museum-publish-sync-rolls-back-installation-failures ()
  "A failed mirror installation restores the prior published bytes."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-rollback-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (org-museum-test--unique-sibling-path root "rollback-publish-site"))
         (export-root (expand-file-name "exports/html" root))
         (published-index (expand-file-name "index.html"
                                             org-museum-publish-directory))
         (original-copy-file (symbol-function 'copy-file)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" export-root) t)
          (make-directory (expand-file-name "pages/nested" export-root) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (make-directory org-museum-publish-directory t)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "NEW INDEX"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (with-temp-file (expand-file-name "related.html" export-root)
            (insert "RELATED"))
          (with-temp-file (expand-file-name "timeline.html" export-root)
            (insert "TIMELINE"))
          (with-temp-file (expand-file-name "pages/nested/new.html" export-root)
            (insert "NESTED"))
          (with-temp-file published-index (insert "OLD INDEX"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json"
                                org-museum-publish-directory)
            (insert "{\"schemaVersion\":1,\"files\":[\"index.html\"]}"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'copy-file)
                     (lambda (source destination &rest args)
                        (if (and
                             (string-prefix-p
                              (file-name-as-directory
                               (expand-file-name org-museum-publish-directory))
                              (expand-file-name destination))
                             (string-suffix-p
                              "pages/nested/new.html"
                              (replace-regexp-in-string
                               "\\\\" "/" (expand-file-name destination))))
                            (error "fixture install failure")
                          (apply original-copy-file source destination args)))))
            (should-error (org-museum-publish-sync)
                          :type 'org-museum-publish-error))
          (should (equal (org-museum-test--file-string published-index)
                         "OLD INDEX"))
          (should-not
           (file-directory-p
            (expand-file-name "pages/nested" org-museum-publish-directory))))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t)))))

(ert-deftest org-museum-publish-sync-rejects-linked-destinations ()
  "A managed destination link cannot redirect writes outside the checkout."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-link-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory (expand-file-name "publish" root))
         (export-root (expand-file-name "exports/html" root))
         (outside (expand-file-name "outside" root))
         (linked-pages (expand-file-name "pages" org-museum-publish-directory))
         (original-file-symlink-p (symbol-function 'file-symlink-p)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" export-root) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (make-directory org-museum-publish-directory t)
          (make-directory outside t)
          (make-directory linked-pages t)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "INDEX"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (with-temp-file (expand-file-name "related.html" export-root)
            (insert "RELATED"))
          (with-temp-file (expand-file-name "pages/new.html" export-root)
            (insert "NEW"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore)
                    ((symbol-function 'file-symlink-p)
                     (lambda (path)
                       (if (equal (directory-file-name (expand-file-name path))
                                  (directory-file-name linked-pages))
                           outside
                         (funcall original-file-symlink-p path)))))
            (should-error (org-museum-publish-sync)
                          :type 'org-museum-publish-error))
          (should-not (file-exists-p (expand-file-name "new.html" outside))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-sync-removes-a-new-root-after-failure ()
  "A failed first installation leaves no newly-created publish checkout."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-new-root-test-" t)))
         (staging (expand-file-name "staging" root))
         (publish (expand-file-name "publish" root)))
    (unwind-protect
        (progn
          (make-directory staging t)
          (with-temp-file (expand-file-name "index.html" staging)
            (insert "INDEX"))
          (cl-letf (((symbol-function 'copy-file)
                     (lambda (&rest _) (error "fixture copy failure"))))
            (should-error
             (org-museum--publish-apply-staging
              staging publish '("index.html") nil)
             :type 'org-museum-publish-error))
          (should-not (file-exists-p publish)))
      (delete-directory root t))))

(ert-deftest org-museum-publish-rejects-a-dangling-managed-link ()
  "A dangling target link is refused even though `file-exists-p' is nil."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-dangling-test-" t)))
         (target (expand-file-name "pages/dangling.html" root))
         (original-exists (symbol-function 'file-exists-p))
         (original-link (symbol-function 'file-symlink-p)))
    (unwind-protect
        (cl-letf (((symbol-function 'file-exists-p)
                   (lambda (path)
                     (if (equal (expand-file-name path) target)
                         nil
                       (funcall original-exists path))))
                  ((symbol-function 'file-symlink-p)
                   (lambda (path)
                     (if (equal (expand-file-name path) target)
                         "missing-target"
                       (funcall original-link path)))))
          (should-error
           (org-museum--publish-validate-destination-paths root (list target))
           :type 'org-museum-publish-error))
      (delete-directory root t))))

(ert-deftest org-museum-publish-directory-overlap-uses-real-paths ()
  "A linked spelling cannot hide overlap with the wiki or export tree."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-overlap-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory (expand-file-name "outside" root))
         (export-root (expand-file-name "exports/html" root))
         (original-truename (symbol-function 'file-truename)))
    (unwind-protect
        (progn
          (make-directory export-root t)
          (cl-letf (((symbol-function 'file-truename)
                     (lambda (path &rest args)
                       (if (equal (directory-file-name (expand-file-name path))
                                  (directory-file-name
                                   org-museum-publish-directory))
                           (expand-file-name "pages" root)
                         (apply original-truename path args)))))
            (should-error (org-museum--publish-validate-directories)
                          :type 'org-museum-publish-error)))
      (delete-directory root t))))

(ert-deftest org-museum-publish-deploy-commits-pushes-and-enables-pages ()
  "A clean managed update is committed, pushed, and configured for Pages."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-deploy-test-" t)))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         (org-museum-publish-branch "main")
         (org-museum-publish-remote "origin")
         (manifest-json
          (concat
           "{\"schemaVersion\":1,\"files\":[\".nojekyll\","
           "\".org-museum-publish-status.json\",\"index.html\"]}"))
         calls)
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root) t)
          (with-temp-file (expand-file-name "index.html" root) (insert "INDEX"))
          (with-temp-file (expand-file-name ".nojekyll" root))
          (with-temp-file
              (expand-file-name ".org-museum-publish-status.json" root)
            (insert "{\"schemaVersion\":1,\"state\":\"ready\","
                    "\"blockedPages\":[]}"))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert manifest-json))
          (cl-letf
              (((symbol-function 'org-museum--publish-run)
                (lambda (program arguments &optional _accepted)
                  (push (cons program arguments) calls)
                  (cond
                   ((equal arguments
                           '("show" "HEAD:.org-museum-publish-manifest.json"))
                    (cons 0 manifest-json))
                   ((equal arguments
                           '("status" "--porcelain=v1" "-z"
                             "--untracked-files=all"))
                    (cons 0 (concat " M index.html\0"
                                    " M .org-museum-publish-manifest.json\0")))
                   ((equal arguments '("remote" "get-url" "origin"))
                    (cons 0 "https://github.com/example/org-notes.git\n"))
                   ((equal arguments
                           '("symbolic-ref" "--quiet" "--short" "HEAD"))
                    (cons 0 "main\n"))
                   ((equal (car arguments) "ls-remote") (cons 2 ""))
                   ((equal arguments '("diff" "--cached" "--quiet"))
                    (cons 1 ""))
                   ((and (equal program "gh")
                          (equal (car arguments) "api")
                          (not (member "-X" arguments)))
                     (cons 1 "not found"))
                    ((equal arguments '("rev-parse" "HEAD"))
                     (cons 0 "0123456789abcdef\n"))
                    (t (cons 0 ""))))))
            (should (equal (org-museum-publish-deploy)
                           "https://example.github.io/org-notes/")))
          (should (cl-find-if
                   (lambda (call)
                     (equal call '("git" "push" "-u" "origin" "main")))
                   calls))
          (should (cl-find-if
                   (lambda (call)
                     (and (equal (car call) "gh")
                           (member "POST" (cdr call))
                           (member "source[path]=/" (cdr call))))
                    calls))
          (with-current-buffer "*Org Museum 发布*"
            (should (string-match-p "0123456789abcdef" (buffer-string)))
            (should (string-match-p
                     "https://github.com/example/org-notes"
                     (buffer-string)))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-push-retries-github-commit-refs-failure ()
  "A transient GitHub ref-commit failure is retried exactly once."
  (let ((org-museum-publish-remote "origin")
        calls
        sleeps)
    (cl-letf (((symbol-function 'org-museum--publish-run)
               (lambda (program arguments &optional accepted)
                 (push (list program arguments accepted) calls)
                 (if (= (length calls) 1)
                     (cons 1 (concat "remote: fatal error in commit_refs\n"
                                     "! [remote rejected] main -> main (failure)"))
                   (cons 0 ""))))
              ((symbol-function 'sleep-for)
               (lambda (seconds &optional _milliseconds)
                 (push seconds sleeps))))
      (should (equal (org-museum--publish-push "main") (cons 0 "")))
      (should (= (length calls) 2))
      (should (equal sleeps '(2)))
      (should (equal (cadar calls) '("push" "-u" "origin" "main"))))))

(ert-deftest org-museum-publish-push-does-not-retry-policy-failures ()
  "A normal Git rejection remains visible and is not retried."
  (let ((org-museum-publish-remote "origin")
        (calls 0))
    (cl-letf (((symbol-function 'org-museum--publish-run)
               (lambda (_program _arguments &optional _accepted)
                 (cl-incf calls)
                 (cons 1 "remote: push declined due to repository rule"))))
      (should-error (org-museum--publish-push "main")
                    :type 'org-museum-publish-error)
      (should (= calls 1)))))

(ert-deftest org-museum-publish-deploy-configures-missing-identity-locally ()
  "A deploy can commit without relying on global Git identity settings."
  (let ((org-museum-publish-directory "C:/publish/")
        (org-museum-publish-repository "example/org-notes")
        calls)
    (cl-letf (((symbol-function 'org-museum--publish-run)
               (lambda (program arguments &optional _accepted)
                 (push (cons program arguments) calls)
                 (cond
                  ((and (equal program "git")
                        (equal arguments '("config" "--local" "--get" "user.name")))
                   (cons 1 ""))
                  ((and (equal program "git")
                        (equal arguments '("config" "--local" "--get" "user.email")))
                   (cons 1 ""))
                  ((and (equal program "gh")
                        (equal arguments
                               '("api" "user" "--jq" "[.id, .login] | @tsv")))
                   (cons 0 "12345\texample\n"))
                  (t (cons 0 ""))))))
      (org-museum--publish-ensure-git-identity
       org-museum-publish-repository)
      (should (member
               '("git" "config" "--local" "user.name" "example") calls))
      (should (member
               '("git" "config" "--local" "user.email"
                 "12345+example@users.noreply.github.com")
               calls))
      (should-not
       (cl-find-if (lambda (call) (member "--global" (cdr call))) calls)))))

(ert-deftest org-museum-publish-deploy-rejects-a-lookalike-remote-host ()
  "A repository-shaped path on a non-GitHub host is never pushed."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-remote-test-" t)))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         (org-museum-publish-branch "main")
         (org-museum-publish-remote "origin")
         (manifest-json
          "{\"schemaVersion\":1,\"files\":[\".nojekyll\",\"index.html\"]}"))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root) t)
          (with-temp-file (expand-file-name "index.html" root) (insert "INDEX"))
          (with-temp-file (expand-file-name ".nojekyll" root))
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert manifest-json))
          (cl-letf
              (((symbol-function 'org-museum--publish-run)
                (lambda (_program arguments &optional _accepted)
                  (cond
                   ((equal arguments
                           '("show" "HEAD:.org-museum-publish-manifest.json"))
                    (cons 0 manifest-json))
                   ((equal (car arguments) "status") (cons 0 ""))
                   ((equal (car arguments) "get-url")
                    (cons 0 "https://attacker.example/example/org-notes.git"))
                   ((equal arguments '("remote" "get-url" "origin"))
                    (cons 0 "https://attacker.example/example/org-notes.git"))
                   (t (cons 0 ""))))))
            (should-error (org-museum-publish-deploy)
                          :type 'org-museum-publish-error)))
      (delete-directory root t))))

(ert-deftest org-museum-publish-git-status-parses-worktree-renames ()
  "Either porcelain status column can introduce the second rename path."
  (cl-letf (((symbol-function 'org-museum--publish-run)
             (lambda (&rest _)
               (cons 0 (concat " R pages/new.html\0pages/old.html\0")))))
    (should (equal (org-museum--publish-git-status-paths)
                   '("pages/old.html" "pages/new.html")))))

(ert-deftest org-museum-publish-git-status-decodes-unicode-paths ()
  "Real Git porcelain output preserves UTF-8 managed relative paths."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-unicode-git-" t)))
         (org-museum-publish-directory root)
         (relative "pages/学习.html")
         (file (expand-file-name relative root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (org-museum--publish-run "git" '("init" "-b" "main"))
          (with-temp-file file (insert "published"))
          (should (member relative
                          (org-museum--publish-git-status-paths)))
          (org-museum--publish-run "git" (list "add" "--" relative))
          (should (member
                   relative
                   (split-string
                    (cdr (org-museum--publish-run
                          "git" '("diff" "--cached" "--name-only" "-z")))
                    "\0" t))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-command-output-redacts-url-credentials ()
  "Persistent publish logs never retain URL userinfo or GitHub tokens."
  (let ((redacted
         (org-museum--publish-redact-command-output
          "https://gho_secret@github.com/example/org-notes.git github_pat_token")))
    (should-not (string-match-p "gho_secret\|github_pat_token" redacted))
    (should (string-match-p "https://\\*\\*\\*@github.com" redacted))))

(ert-deftest org-museum-publish-run-keeps-raw-output-for-machine-parsing ()
  "Only the persistent log is redacted; callers receive exact process bytes."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-output-test-" t)))
         (org-museum-publish-directory root)
         (payload " M pages/ghp_legitimate-name.html\0"))
    (unwind-protect
        (progn
          (when (get-buffer "*Org Museum 发布*")
            (kill-buffer "*Org Museum 发布*"))
          (cl-letf (((symbol-function 'executable-find) (lambda (_) t))
                    ((symbol-function 'process-file)
                     (lambda (_program _in destination _display &rest _args)
                       (with-current-buffer destination (insert payload))
                       0)))
            (should (equal (cdr (org-museum--publish-run "git" '("status")))
                           payload)))
          (with-current-buffer "*Org Museum 发布*"
            (should-not (search-forward "ghp_legitimate" nil t))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-run-reports-a-missing-executable ()
  "Deployment prerequisites fail before any subprocess is attempted."
  (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil)))
    (should-error (org-museum--publish-run "missing-publisher" nil)
                  :type 'org-museum-publish-error)))

(ert-deftest org-museum-publish-bootstrap-requires-explicit-confirmation ()
  "First-time public repository creation is cancelled without consent."
  (let ((called nil))
    (cl-letf (((symbol-function 'org-museum--publish-confirm-bootstrap)
               (lambda (&rest _) nil))
              ((symbol-function 'org-museum--publish-run)
               (lambda (&rest _) (setq called t))))
      (should-error
       (org-museum--publish-bootstrap-repository
        "C:/publish/" "example/org-notes" "main")
       :type 'org-museum-publish-error)
      (should-not called))))

(ert-deftest org-museum-publish-bootstrap-creates-a-public-main-repository ()
  "Confirmed first-time setup initialises Git and requests a public repository."
  (let ((org-museum-publish-remote "origin") calls)
    (cl-letf (((symbol-function 'org-museum--publish-confirm-bootstrap)
               (lambda (&rest _) t))
              ((symbol-function 'org-museum--publish-run)
               (lambda (program arguments &optional _accepted)
                 (push (cons program arguments) calls)
                 (cons 0 ""))))
      (org-museum--publish-bootstrap-repository
       "C:/publish/" "example/org-notes" "main")
      (should (member '("git" "init" "-b" "main") calls))
      (should (cl-find-if
               (lambda (call)
                 (and (equal (car call) "gh")
                      (member "--public" (cdr call))
                      (member "example/org-notes" (cdr call))))
               calls)))))

(ert-deftest org-museum-publish-deploy-stops-when-gh-is-unauthenticated ()
  "An unauthenticated GitHub CLI cannot initialise or push the checkout."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-auth-test-" t)))
         (org-museum-publish-directory root)
         (org-museum-publish-repository "example/org-notes")
         (org-museum-publish-branch "main")
         (org-museum-publish-remote "origin")
         (bootstrapped nil))
    (unwind-protect
        (progn
          (with-temp-file
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert "{\"schemaVersion\":1,\"files\":[\"index.html\"]}"))
          (with-temp-file (expand-file-name "index.html" root) (insert "INDEX"))
          (cl-letf (((symbol-function 'org-museum--publish-run)
                     (lambda (program arguments &optional _accepted)
                       (if (and (equal program "gh")
                                (equal arguments '("auth" "status")))
                           (signal 'org-museum-publish-error
                                   '("GitHub CLI is not authenticated"))
                         (cons 0 ""))))
                    ((symbol-function 'org-museum--publish-bootstrap-repository)
                     (lambda (&rest _) (setq bootstrapped t))))
            (should-error (org-museum-publish-deploy)
                          :type 'org-museum-publish-error)
            (should-not bootstrapped)))
      (delete-directory root t))))

(ert-deftest org-museum-publish-rejects-remote-ahead-or-diverged-history ()
  "A fetched remote commit not contained in HEAD requires manual recovery."
  (cl-letf (((symbol-function 'org-museum--publish-run)
             (lambda (_program arguments &optional _accepted)
               (cond
                ((equal (car arguments) "ls-remote") (cons 0 "remote"))
                ((equal (car arguments) "fetch") (cons 0 ""))
                ((equal arguments '("rev-parse" "--verify" "HEAD"))
                 (cons 0 "head"))
                ((equal (car arguments) "merge-base") (cons 1 ""))
                (t (cons 0 ""))))))
    (should-error (org-museum--publish-check-remote-history "main")
                  :type 'org-museum-publish-error)))

(ert-deftest org-museum-publish-unchanged-tree-does-not-create-a-commit ()
  "An unchanged managed tree finishes without an empty Git commit."
  (let (calls)
    (cl-letf (((symbol-function 'org-museum--publish-run)
               (lambda (program arguments &optional _accepted)
                 (push (cons program arguments) calls)
                 (cons 0 ""))))
      (should-not (org-museum--publish-stage-and-commit nil))
      (should-not (cl-find-if
                   (lambda (call) (member "commit" (cdr call))) calls)))))

(ert-deftest org-museum-publish-pages-api-failure-is-not-hidden ()
  "A Pages update failure remains a deployment error after a successful push."
  (cl-letf (((symbol-function 'org-museum--publish-run)
             (lambda (_program arguments &optional _accepted)
               (if (member "-X" arguments)
                   (signal 'org-museum-publish-error '("Pages update failed"))
                 (cons 0 "{}")))))
    (should-error
     (org-museum--publish-configure-pages "example/org-notes" "main")
     :type 'org-museum-publish-error)))

(ert-deftest org-museum-publish-commands-have-daily-workflow-bindings ()
  "Both publishing stages are reachable without requiring Transient."
  (should (eq (lookup-key org-museum-mode-map (kbd "C-c w p"))
              #'org-museum-publish-sync))
  (should (eq (lookup-key org-museum-mode-map (kbd "C-c w P"))
               #'org-museum-publish-deploy))
  (let ((fallback (prin1-to-string
                   (symbol-function 'org-museum--dispatch-minibuffer))))
    (should (string-match-p "org-museum-publish-sync" fallback))
    (should (string-match-p "org-museum-publish-deploy" fallback)))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "org-museum.el"
                                            org-museum-test--repo-root))
    (should (search-forward
             "(\"p\" \"同步发布站点\"   org-museum-publish-sync)" nil t))
    (should (search-forward
             "(\"P\" \"部署到 GitHub\" org-museum-publish-deploy)"
             nil t))))

(defun org-museum-test--curation-fixture (root)
  "Create and index a two-page curation fixture beneath ROOT."
  (let ((pages (expand-file-name "pages" root)))
    (make-directory pages t)
    (with-temp-file (expand-file-name "source.org" pages)
      (insert "#+TITLE: Source\n#+WIKI_ID: source\n#+CATEGORY: Test\n"
              "#+WIKI_STATUS: published\n#+DATE: 2026-09-01\n#+FILETAGS: :test:\n\n* Body\nText.\n"))
    (with-temp-file (expand-file-name "target.org" pages)
      (insert "#+TITLE: Target\n#+WIKI_ID: target\n#+CATEGORY: Test\n"
              "#+WIKI_STATUS: published\n#+DATE: 2026-09-02\n#+FILETAGS: :test:\n\n* Body\nTarget.\n"))
    (org-museum-index-build t)))

(ert-deftest org-museum-curation-rejects-unknown-fields-and-stale-hashes ()
  (let* ((root (make-temp-file "org-museum-curation-validation-" t))
         (org-museum-root-dir root) (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages") org-museum--index)
    (unwind-protect
        (progn
          (org-museum-test--curation-fixture root)
          (should-error
           (org-museum-curation-preview
            '((schemaVersion . 1) (pageId . "source") (expectedSha256 . "bad")
              (changes . ()) (relations . ()) (elisp . "(delete-directory \"/\")")))
           :type 'org-museum-curation-error)
          (should-error
           (org-museum-curation-preview
            '((schemaVersion . 1) (pageId . "source") (expectedSha256 . "bad")
              (changes . ()) (relations . ())))
           :type 'org-museum-curation-error))
      (delete-directory root t))))

(ert-deftest org-museum-curation-managed-relations-are-additive-and-removable ()
  (let* ((root (make-temp-file "org-museum-curation-relations-" t))
         (org-museum-root-dir root) (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages") org-museum--index)
    (unwind-protect
        (progn
          (org-museum-test--curation-fixture root)
          (let* ((base "#+TITLE: Source\n\n* Body\nText.\n")
                 (added (org-museum--curation-apply-relations
                         base '(((action . "add") (targetId . "target") (type . "相关")))))
                 (removed (org-museum--curation-apply-relations
                           added '(((action . "remove") (targetId . "target") (type . "相关"))))))
            (should (string-match-p (regexp-quote "#+MUSEUM_RELATION: target | 相关") added))
            (should (string-match-p (regexp-quote ":ORG_MUSEUM_MANAGED: t") added))
            (should-not (string-match-p (regexp-quote "[[wiki:target]") removed))
            (should-not (string-match-p (regexp-quote "MUSEUM_RELATION: target") removed))))
      (delete-directory root t))))

(ert-deftest org-museum-curation-paths-stay-inside-pages ()
  (let* ((root (make-temp-file "org-museum-curation-path-" t))
         (org-museum-root-dir root) (org-museum-pages-subdir "pages"))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" root) t)
          (should-error (org-museum--curation-safe-target-path "../escape.org")
                        :type 'org-museum-curation-error)
          (should-error (org-museum--curation-safe-target-path "CON.org")
                        :type 'org-museum-curation-error)
          (should (file-in-directory-p
                   (org-museum--curation-safe-target-path "ontology/safe.org")
                   (expand-file-name "pages" root))))
      (delete-directory root t))))

(ert-deftest org-museum-curation-preview-normalizes-metadata-without-writing ()
  (let* ((root (make-temp-file "org-museum-curation-preview-" t))
         (org-museum-root-dir root) (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages") org-museum--index
         (source (expand-file-name "pages/source.org" root)))
    (unwind-protect
        (progn
          (org-museum-test--curation-fixture root)
          (let* ((before (org-museum-test--file-string source))
                 (transaction
                  (org-museum-curation-preview
                   `((schemaVersion . 1) (pageId . "source")
                     (expectedSha256 . ,(org-museum--curation-sha256 source))
                     (changes . ((title . "Curated") (status . "draft")
                                 (tags . ["safe" "reviewed"])))
                     (relations . ())))))
            (should (string-match-p (regexp-quote "#+TITLE: Curated")
                                    (plist-get transaction :after)))
            (should (string-match-p (regexp-quote "#+FILETAGS: :safe:reviewed:")
                                    (plist-get transaction :after)))
            (should (equal before (org-museum-test--file-string source)))))
      (delete-directory root t))))

(ert-deftest org-museum-curation-apply-rolls-back-when-export-fails ()
  (let* ((root (make-temp-file "org-museum-curation-rollback-" t))
         (backup (make-temp-file "org-museum-curation-backup-" t))
         (org-museum-root-dir root) (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-curation-backup-directory backup) org-museum--index
         (source (expand-file-name "pages/source.org" root)))
    (unwind-protect
        (progn
          (org-museum-test--curation-fixture root)
          (let* ((before (org-museum-test--file-string source))
                 (transaction
                  (org-museum-curation-preview
                   `((schemaVersion . 1) (pageId . "source")
                     (expectedSha256 . ,(org-museum--curation-sha256 source))
                     (changes . ((title . "Must Roll Back"))) (relations . ())))))
            (cl-letf (((symbol-function 'org-museum-export-all)
                       (lambda () (error "fixture export failure"))))
              (should-error (org-museum-curation-apply (plist-get transaction :id))
                            :type 'error))
            (should (equal before (org-museum-test--file-string source)))
            (should (directory-files backup nil "^[^.].*"))))
      (delete-directory root t)
      (delete-directory backup t))))

(ert-deftest org-museum-curation-loopback-rejects-wrong-token-and-origin ()
  (let ((org-museum--curation-token "fixture-token")
        (org-museum--curation-server-port 49152))
    (should-not
     (org-museum--curation-authorized-p
      '(("authorization" . "Bearer wrong-token")
        ("x-org-museum-curation" . "1")
        ("origin" . "http://127.0.0.1:49152"))))
    (should-not
     (org-museum--curation-authorized-p
      '(("authorization" . "Bearer fixture-token")
        ("x-org-museum-curation" . "1")
        ("origin" . "https://example.invalid"))))
    (should
     (org-museum--curation-authorized-p
      '(("authorization" . "Bearer fixture-token")
        ("x-org-museum-curation" . "1")
        ("origin" . "http://localhost:49152"))))
    (should (string-prefix-p
             "HTTP/1.1 409"
             (org-museum--curation-dispatch-http
              "GET" "/api/v1/session"
              '(("authorization" . "Bearer wrong-token")
                ("x-org-museum-curation" . "1")) "")))))

(ert-deftest org-museum-curation-server-stop-invalidates-session ()
  (let ((org-museum--curation-server nil)
        (org-museum--curation-token "fixture-token")
        (org-museum--curation-server-port 49152)
        (org-museum--curation-transactions (make-hash-table :test #'equal)))
    (puthash "transaction" '(:id "transaction")
             org-museum--curation-transactions)
    (org-museum-curation-server-stop)
    (should-not org-museum--curation-token)
    (should-not org-museum--curation-server-port)
    (should (= 0 (hash-table-count org-museum--curation-transactions)))))

(ert-deftest org-museum-round23-interactions-are-exported ()
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" nil))
        (related (org-museum--script-related-reading)))
    (should (string-match-p (regexp-quote "id=\"btn-layout\"") graph))
    (should (string-match-p (regexp-quote "workspaceFooter.hidden=state.view==='triage'") graph))
    (should (string-match-p
             (regexp-quote "<h2 id=\"graph-selected-title\">尚未选择笔记</h2>")
             graph))
    (should (string-match-p (regexp-quote "data-related-pane") related))
    (should (string-match-p (regexp-quote "syncScroll") related)))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "resources/org-museum-theme.js"
                                            org-museum-test--repo-root))
    (should (search-forward "orgMuseumCuration" nil t))
    (should-not (search-forward "/api/v1/" nil t)))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "resources/org-museum-curation.js"
                                            org-museum-test--repo-root))
    (goto-char (point-min))
    (should (search-forward "sessionStorage" nil t))))

(ert-deftest org-museum-timeline-states-published-boundary-explicitly ()
  (let ((html (org-museum--build-timeline-html
               "timeline.html"
               "{\"pages\":[],\"edges\":[],\"palette\":[]}")))
    (should (string-match-p
             (regexp-quote "按创建时间浏览已发布笔记") html))
    (should (string-match-p
             (regexp-quote "已发布笔记") html))
    (should (string-match-p
             (regexp-quote "当前时间轴仅展示已发布笔记") html))
    (should-not (string-match-p
                 (regexp-quote "id=\"timeline-status-filters\" class=\"timeline-filter-list\"")
                 html))))

(ert-deftest org-museum-assets-classify-by-mime-and-render-by-kind ()
  "Asset behaviour is selected from MIME-derived kinds, not filename branches."
  (should (equal (org-museum--asset-mime-for-name "query.sql")
                 "application/sql"))
  (should (equal (org-museum--asset-published-name "abc" "application/sql")
                 "abc.sql"))
  (should (eq (org-museum--asset-kind-for-mime "image/png") 'image))
  (should (eq (org-museum--asset-kind-for-mime "video/mp4") 'video))
  (should (eq (org-museum--asset-kind-for-mime "audio/mpeg") 'audio))
  (should (eq (org-museum--asset-kind-for-mime "application/pdf") 'pdf))
  (should (eq (org-museum--asset-kind-for-mime
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
              'spreadsheet))
  (should (eq (org-museum--asset-kind-for-mime "application/x-fixture")
              'unknown))
  (let* ((asset (make-org-museum-asset
                 :id (make-string 64 ?a) :filename "demo.png"
                 :mime "image/png" :kind 'image :size 3
                 :sha256 (make-string 64 ?a)
                 :source-path "file:demo.png"
                 :published-url (concat "assets/" (make-string 64 ?a) ".png")
                 :thumbnail (concat "assets/" (make-string 64 ?a) ".png")
                 :filenames '("demo.png") :sources '("file:demo.png"))))
    (let ((html (org-museum--asset-render-html asset "../../../dist/pages/demo.html"
                                                "Demo image" nil)))
      (should (string-match-p "loading=\"lazy\"" html))
      (should (string-match-p "decoding=\"async\"" html))
      (should (string-match-p "data-lightbox" html)))
    (should (string-match-p
             "download=\"demo.png\""
             (org-museum--asset-render-html
              asset "../../../dist/pages/demo.html" nil t)))))

(ert-deftest org-museum-assets-deduplicate-content-and-write-stable-manifest ()
  "Two references with identical bytes publish one content-addressed asset."
  (let* ((root (make-temp-file "org-museum-assets-test-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "dist")
         (org-museum-assets-subdir "assets")
         (left (expand-file-name "left/demo.bin" root))
         (right (expand-file-name "right/copy.bin" root))
         (org-museum--asset-registry (make-hash-table :test #'equal))
         (org-museum--page-assets (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (dolist (file (list left right))
            (make-directory (file-name-directory file) t)
            (with-temp-file file (set-buffer-multibyte nil) (insert "same")))
          (let ((first (org-museum--asset-register-local
                        left "file:left/demo.bin" "page-a" "First" t))
                (second (org-museum--asset-register-local
                         right "file:right/copy.bin" "page-b" "Second" t)))
            (should (equal (org-museum-asset-id first)
                           (org-museum-asset-id second)))
            (should (= 1 (hash-table-count org-museum--asset-registry)))
            (org-museum--publish-assets)
            (org-museum--write-assets-manifest)
            (should (= 1 (length (directory-files
                                  (expand-file-name "dist/assets" root)
                                  nil "^[^.].*"))))
            (with-temp-buffer
              (insert-file-contents (expand-file-name "dist/assets.json" root))
              (let ((json (buffer-string)))
                (should (string-match-p "\"schema_version\":1" json))
                (should (string-match-p "\"page-a\"" json))
                (should (string-match-p "\"page-b\"" json))
                (should-not (string-match-p "[A-Za-z]:[/\\\\]" json))))))
      (delete-directory root t))))

(ert-deftest org-museum-assets-reject-missing-and-empty-local-files ()
  "Broken local assets fail before publication instead of degrading silently."
  (let* ((root (make-temp-file "org-museum-broken-asset-test-" t))
         (empty (expand-file-name "empty.pdf" root))
         (missing (expand-file-name "missing.pdf" root))
         (org-museum-root-dir root)
         (org-museum--asset-registry (make-hash-table :test #'equal))
         (org-museum--page-assets (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file empty)
          (should-error
           (org-museum--asset-register-local
            missing "file:missing.pdf" "page" "Missing" t)
           :type 'org-museum-asset-error)
          (should-error
           (org-museum--asset-register-local
            empty "file:empty.pdf" "page" "Empty" t)
           :type 'org-museum-asset-error))
      (delete-directory root t))))

(ert-deftest org-museum-assets-ignore-hidden-headline-links ()
  "Private Org trees must not leak files into the public asset list."
  (with-temp-buffer
    (insert "* COMMENT Hidden\n[[file:private.pdf]]\n"
            "* Tagged :noexport:\n[[file:tagged.pdf]]\n"
            "* Visible\n[[file:public.pdf]]\n")
    (org-mode)
    (let ((links (org-element-map (org-element-parse-buffer) 'link #'identity)))
      (should (equal (mapcar #'org-museum--asset-link-exported-p links)
                     '(nil nil t))))))

(ert-deftest org-museum-assets-list-only-adds-media-downloads ()
  "An inline file card must not be repeated in the article resource list."
  (let* ((org-museum--asset-registry (make-hash-table :test #'equal))
         (org-museum--page-assets (make-hash-table :test #'equal))
         (page (make-org-museum-page :id "page"))
         (file (make-org-museum-asset :id "file" :filename "query.sql"
                                      :kind 'unknown))
         (image (make-org-museum-asset :id "image" :filename "chart.png"
                                       :kind 'image :published-url "assets/chart.png")))
    (puthash "file" file org-museum--asset-registry)
    (puthash "image" image org-museum--asset-registry)
    (puthash "page" '("file") org-museum--page-assets)
    (should-not (org-museum--page-assets-html page "dist/pages/page.html"))
    (puthash "page" '("file" "image") org-museum--page-assets)
    (let ((org-museum-root-dir temporary-file-directory)
          (org-museum-shared-export-dir "dist"))
      (let ((html (org-museum--page-assets-html page "dist/pages/page.html")))
        (should (string-match-p "chart.png" html))
        (should-not (string-match-p "query.sql" html))))))

(ert-deftest org-museum-assets-single-page-manifest-merge-preserves-other-pages ()
  "Single-page asset updates retain records belonging to other pages."
  (let* ((root (make-temp-file "org-museum-asset-merge-test-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "dist")
         (org-museum-assets-subdir "assets")
         (one (expand-file-name "one.pdf" root))
         (two (expand-file-name "two.pdf" root)))
    (unwind-protect
        (progn
          (with-temp-file one (insert "one"))
          (with-temp-file two (insert "two"))
          (let ((org-museum--asset-registry (make-hash-table :test #'equal))
                (org-museum--page-assets (make-hash-table :test #'equal)))
            (org-museum--asset-register-local
             one "file:one.pdf" "page-one" "One" t)
            (org-museum--asset-register-local
             two "file:two.pdf" "page-two" "Two" t)
            (org-museum--publish-assets)
            (org-museum--write-assets-manifest))
          (let ((org-museum--asset-registry (make-hash-table :test #'equal))
                (org-museum--page-assets (make-hash-table :test #'equal)))
            (org-museum--load-assets-manifest)
            (should (= 2 (hash-table-count org-museum--asset-registry)))
            (should (= 1 (length (gethash "page-two" org-museum--page-assets))))
            (puthash "page-one" nil org-museum--page-assets)
            (org-museum--prune-unreferenced-assets)
            (org-museum--write-assets-manifest)
            (with-temp-buffer
              (insert-file-contents (org-museum--assets-manifest-path))
              (let ((json (buffer-string)))
                (should (string-match-p "\"page-two\"" json))
                (should-not (string-match-p "\"page-one\"" json))))))
      (delete-directory root t))))

(ert-deftest org-museum-assets-single-page-detects-asset-only-change ()
  "Single-page export rehashes an attachment even when the Org file is unchanged."
  (let* ((root (make-temp-file "org-museum-asset-page-refresh-" t))
         (pages (expand-file-name "pages/Test" root))
         (source (expand-file-name "page.org" pages))
         (asset (expand-file-name "data.bin" pages))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "dist/pages")
         (org-museum-shared-export-dir "dist")
         (org-museum-open-browser-after-export nil)
         old-id new-id)
    (unwind-protect
        (progn
          (make-directory pages t)
          (with-temp-file asset (insert "first"))
          (with-temp-file source
            (insert "#+TITLE: Page\n#+WIKI_ID: page\n#+CATEGORY: Test\n"
                    "[[file:data.bin][Data]]\n"))
          (org-museum-export-all)
          (setq old-id (org-museum--file-content-hash asset))
          (let ((source-time (file-attribute-modification-time
                              (file-attributes source))))
            (with-temp-file asset (insert "second"))
            (org-museum-export-page source nil)
            (should (equal source-time
                           (file-attribute-modification-time
                            (file-attributes source)))))
          (setq new-id (org-museum--file-content-hash asset))
          (should-not (equal old-id new-id))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "dist/assets.json" root))
            (should (search-forward new-id nil t))
            (should-not (search-forward old-id nil t)))
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "dist/pages/Test/page.html" root))
            (should (search-forward new-id nil t))))
      (delete-directory root t))))

(ert-deftest org-museum-assets-full-export-publishes-mixed-media-and-page-list ()
  "A real full export publishes mixed asset kinds under dist/assets."
  (let* ((root (make-temp-file "org-museum-assets-export-test-" t))
         (pages (expand-file-name "pages/Test" root))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
         (org-museum-pages-subdir "pages")
         (org-museum-export-dir "dist/pages")
         (org-museum-shared-export-dir "dist")
         (org-museum-assets-subdir "assets")
         (org-museum-open-browser-after-export nil)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (default-buffer-file-coding-system 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (process-environment
          (cons "SOURCE_DATE_EPOCH=1700000000" process-environment)))
    (unwind-protect
        (progn
          (make-directory pages t)
          (dolist (fixture '(("photo.png" . "png-bytes")
                             ("movie.mp4" . "mp4-bytes")
                             ("sound.mp3" . "mp3-bytes")
                             ("paper.pdf" . "pdf-bytes")
                             ("sheet.xlsx" . "xlsx-bytes")
                             ("blob.mystery" . "mystery-bytes")
                             ("photo-copy.png" . "png-bytes")))
            (with-temp-file (expand-file-name (car fixture) pages)
              (set-buffer-multibyte nil)
              (insert (cdr fixture))))
          (with-temp-file (expand-file-name "article.org" pages)
            (insert "#+TITLE: Assets\n#+WIKI_ID: assets\n#+CATEGORY: Test\n\n"
                    "[[file:photo.png][Photo alt]]\n"
                    "[[file:movie.mp4][Movie]]\n"
                    "[[file:sound.mp3][Sound]]\n"
                    "[[file:paper.pdf][Paper]]\n"
                    "[[file:sheet.xlsx][Sheet]]\n"
                    "[[file:blob.mystery][Blob]]\n"
                    "[[file:photo-copy.png][Duplicate photo]]\n"))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (&rest _) (ert-fail "asset fixture used network")))
                    ((symbol-function 'browse-url) (lambda (&rest _) nil)))
            (org-museum-export-all))
          (let ((html (expand-file-name "dist/pages/Test/article.html" root))
                (manifest (expand-file-name "dist/assets.json" root))
                (assets-dir (expand-file-name "dist/assets" root)))
            (should (file-regular-p html))
            (should (file-regular-p manifest))
            (should (= 6 (length (directory-files assets-dir nil "^[^.].*"))))
            (with-temp-buffer
              (insert-file-contents html)
              (should (search-forward "museum-asset-image" nil t))
              (should (search-forward "<video controls preload=\"none\">" nil t))
              (should (search-forward "<audio controls preload=\"none\">" nil t))
              (should (search-forward "museum-asset-pdf" nil t))
              (should (search-forward "id=\"museum-page-assets-title\"" nil t))
              (should-not
               (string-match-p
                "<!-- [0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}"
                (buffer-string))))
            (with-temp-buffer
              (insert-file-contents manifest)
              (let ((json (buffer-string)))
                (should (string-match-p "\"kind\":\"spreadsheet\"" json))
                (should (string-match-p "\"kind\":\"unknown\"" json))
                (should-not (string-match-p "[A-Za-z]:[/\\\\]" json))))
            (let ((first (org-museum-test--tree-hashes
                          (expand-file-name "dist" root))))
              (delete-directory (expand-file-name "dist" root) t)
              (cl-letf (((symbol-function 'url-copy-file)
                         (lambda (&rest _) (ert-fail "repeat export used network")))
                        ((symbol-function 'browse-url) (lambda (&rest _) nil)))
                (org-museum-export-all))
              (should (equal first
                             (org-museum-test--tree-hashes
                              (expand-file-name "dist" root)))))))
      (delete-directory root t))))

(ert-deftest org-museum-assets-attachment-resolution-survives-page-move ()
  "attachment: resolves from the Org heading ID, not the page directory."
  (let* ((root (make-temp-file "org-museum-attachment-asset-test-" t))
         (org-attach-id-dir (expand-file-name "attach" root))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "dist")
         (old (expand-file-name "pages/old/page.org" root))
         (moved (expand-file-name "pages/new/page.org" root))
         (out (expand-file-name "dist/pages/new/page.html" root))
         (org-museum--asset-registry (make-hash-table :test #'equal))
         (org-museum--page-assets (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory old) t)
          (with-temp-file old
            (insert "#+TITLE: Attachment\n#+WIKI_ID: attachment\n"
                    "* Entry\n:PROPERTIES:\n:ID: asset-entry-id\n:END:\n"
                    "[[attachment:manual.pdf][Manual]]\n"))
          (let ((buffer (find-file-noselect old)))
            (unwind-protect
                (with-current-buffer buffer
                  (org-mode)
                  (goto-char (point-min))
                  (search-forward "* Entry")
                  (let ((directory (org-attach-dir t)))
                    (make-directory directory t)
                    (with-temp-file (expand-file-name "manual.pdf" directory)
                      (insert "pdf"))))
              (when (buffer-live-p buffer) (kill-buffer buffer))))
          (make-directory (file-name-directory moved) t)
          (rename-file old moved)
          (with-temp-buffer
            (insert-file-contents moved)
            (setq buffer-file-name moved)
            (org-mode)
            (org-museum--prepare-page-assets (current-buffer) moved out))
          (should (= 1 (hash-table-count org-museum--asset-registry))))
      (delete-directory root t))))

(ert-deftest org-museum-assets-remote-cache-locks-content-until-refresh ()
  "A warm URL mapping rebuilds without network access until explicitly refreshed."
  (let* ((root (make-temp-file "org-museum-remote-asset-test-" t))
         (org-museum-asset-cache-directory root)
         (url "https://example.test/media/demo.mp3")
         (calls 0))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (cl-incf calls)
                       (let ((buffer (generate-new-buffer " *remote asset*")))
                         (with-current-buffer buffer
                           (set-buffer-multibyte nil)
                           (insert "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n\r\n")
                           (setq-local url-http-end-of-headers (point))
                           (insert "remote-audio"))
                         buffer))))
            (let ((first (org-museum--asset-download-remote url)))
              (should (file-regular-p (plist-get first :path)))
              (should (equal "audio/mpeg" (plist-get first :mime)))))
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _) (ert-fail "warm cache used network"))))
            (should (file-regular-p
                     (plist-get (org-museum--asset-download-remote url) :path))))
          (should (= calls 1))
          (should (= 1 (org-museum-refresh-remote-assets url)))
          (should-not (file-exists-p (org-museum--asset-cache-url-path url))))
      (delete-directory root t))))

(ert-deftest org-museum-assets-remote-candidate-rejects-version-page ()
  "A dotted release version remains a web page while known assets are fetched."
  (should-not
   (org-museum--remote-asset-candidate-p
    "https://github.com/magit/magit/releases/tag/v4.7.0"))
  (should
   (org-museum--remote-asset-candidate-p
    "https://example.test/download/archive.tar.xz"))
  (should
   (org-museum--remote-asset-candidate-p
    "https://example.test/media/opaque.bin")))

(ert-deftest org-museum-assets-remote-html-response-remains-link ()
  "A candidate URL returning HTML is not registered as an asset."
  (let ((org-museum--asset-remote-results (make-hash-table :test #'equal))
        (calls 0))
    (cl-letf (((symbol-function 'org-museum--asset-download-remote)
               (lambda (_url)
                 (cl-incf calls)
                 (signal 'org-museum-asset-error
                         '("Remote asset returned HTML: https://example.test/file.pdf")))))
      (dotimes (_ 2)
        (should-not
         (org-museum--asset-register-remote
          "https://example.test/file.pdf" "page" "Reference" t)))
      (should (= calls 1)))))

(ert-deftest org-museum-assets-preflight-preserves-source-mtime ()
  "Asset discovery never changes an unchanged Org source timestamp."
  (let* ((root (make-temp-file "org-museum-asset-mtime-test-" t))
         (source (expand-file-name "page.org" root))
         (asset (expand-file-name "file.bin" root))
         (old-time (seconds-to-time 1700000000))
         (org-museum-root-dir root)
         (org-museum-export-dir "dist/pages")
         (org-museum-shared-export-dir "dist")
         (org-museum--asset-registry (make-hash-table :test #'equal))
         (org-museum--page-assets (make-hash-table :test #'equal))
         (org-museum--asset-remote-results (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file asset (insert "binary"))
          (with-temp-file source
            (insert "#+TITLE: Page\n#+WIKI_ID: page\n[[file:file.bin][File]]\n"))
          (set-file-times source old-time)
          (org-museum--preflight-page-assets source)
          (should (equal old-time
                         (file-attribute-modification-time
                          (file-attributes source)))))
      (delete-directory root t))))

(ert-deftest org-museum-assets-root-requires-safe-strict-descendant ()
  "Asset cleanup can never target the shared output root or reserved trees."
  (let ((org-museum-root-dir temporary-file-directory)
        (org-museum-shared-export-dir "dist"))
    (dolist (value '("" "." "pages" "resources" "../assets"))
      (let ((org-museum-assets-subdir value))
        (should-error (org-museum--assets-root)
                      :type 'org-museum-asset-error)))))

(ert-deftest org-museum-assets-remote-http-error-retains-link-with-warning ()
  "A missing remote file leaves its link intact and reports each location."
  (let ((org-museum-asset-cache-directory
         (make-temp-file "org-museum-http-error-cache-" t))
        (org-museum--asset-remote-results (make-hash-table :test #'equal))
        (org-museum--asset-warnings nil)
        (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (&rest _)
                     (cl-incf calls)
                     (let ((buffer (generate-new-buffer " *asset 404*")))
                       (with-current-buffer buffer
                         (insert "HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\n\r\nmissing")
                         (setq-local url-http-end-of-headers
                                     (save-excursion
                                       (goto-char (point-min))
                                       (search-forward "\r\n\r\n")))
                         (setq-local url-http-response-status 404))
                       buffer))))
          (dolist (location '("page.org:1" "page.org:2"))
            (let ((org-museum--asset-current-location location))
              (should-not
               (org-museum--asset-register-remote
                "https://example.test/missing.pdf" "page" "PDF" t))))
          (should (= calls 1))
          (should (= (length org-museum--asset-warnings) 2))
          (should (equal (mapcar (lambda (warning)
                                   (plist-get warning :location))
                                 (nreverse org-museum--asset-warnings))
                         '("page.org:1" "page.org:2")))
          (should (eq (plist-get (car org-museum--asset-warnings) :kind)
                      'remote-unavailable)))
      (delete-directory org-museum-asset-cache-directory t))))

(ert-deftest org-museum-generated-list-anchors-are-deterministic ()
  "Process-random Org list anchors normalize by stable document order."
  (let (outputs)
    (dolist (ids '(("orgabcdef1" "org1234567")
                   ("org7654321" "orgfedcba9")))
      (with-temp-buffer
        (insert (format "<li><a id=\"%s\"></a><a href=\"#%s\">One</a></li>"
                        (car ids) (car ids)))
        (insert (format "<li><a id=\"%s\"></a>Two</li>" (cadr ids)))
        (org-museum--pp-stabilize-generated-anchors "page.org")
        (push (buffer-string) outputs)))
    (should (equal (car outputs) (cadr outputs)))
    (should (string-match-p "href=\"#org-museum-ref-" (car outputs)))
    (should-not (string-match-p "orgabcdef1\\|org7654321" (car outputs)))))

(provide 'org-museum-test)

;;; org-museum-test.el ends here
