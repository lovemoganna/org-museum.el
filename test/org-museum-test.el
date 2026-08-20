;;; org-museum-test.el --- Tests for org-museum -*- lexical-binding: t; -*-

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
                    "VictorMono-Roman-v1.564.woff2"
                    "VictorMono-Italic-v1.564.woff2"
                    "OFL-Noto-Sans-CJK.txt"
                    "OFL-Victor-Mono.txt"
                    "SHA256SUMS"))
      (should (file-regular-p
               (expand-file-name (concat "resources/fonts/" name)
                                 org-museum-test--repo-root))))
    (dolist (variable '("--font-reading" "--font-ui"
                        "--font-code" "--font-technical"))
      (should (string-search variable css)))
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
    (should (string-search "objectStore('readingState').delete(record.pageId)" script))))

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
      (when-let ((buffer (get-file-buffer file)))
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
      (when-let ((buffer (get-file-buffer file)))
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
              (should (string-prefix-p "Org Museum [Create]:" message))))
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
      (when-let ((buffer (get-file-buffer file)))
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
                       "Org Museum [Rename]: new ID must be one non-empty path-safe name"
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
                     "Org Museum [Rename]: save the page before renaming"
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
  (should (= org-museum-article-max-width 960))
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
    (should (search-forward "var(--museum-article-max-width, 960px)" nil t))))

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
    (should (string-match-p (regexp-quote ".attr('r',16)") graph))
    (should (string-match-p "node\.labelWidth" graph))
    (should (string-match-p "Math\.max(minX,Math\.min(maxX,node\.x))" graph))
    (should (string-match-p (regexp-quote ".attr('aria-label'") graph))
    (should (string-match-p "event\.key===' '" graph))
    (should (string-match-p "prefers-reduced-motion: reduce" graph))
    (should (string-match-p "if(!reduceMotion)simulation\.on" graph))
    (should (string-match-p
             (regexp-quote
              "layoutTicks=reduceMotion?Math.max(preTicks,160):preTicks")
             graph))
    (should (string-match-p (regexp-quote "16/zoomScale") graph))
    (should (string-match-p "selectedDetail\.hidden=true" graph))))

(ert-deftest org-museum-graph-reflows-after-viewport-changes ()
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-match-p "new ResizeObserver" graph))
    (should (string-match-p "function syncGraphViewport" graph))
    (should (string-search
             "svg.attr('viewBox','0 0 '+width+' '+height)" graph))
    (should (string-search "simulation.force('center'" graph))
    (should (string-search "simulation.alpha(.35).stop()" graph))
    (should (string-search "mobileGraphMedia.addEventListener" graph))
    (should (string-search "filterSummary.open=!mobile" graph))))

(ert-deftest org-museum-graph-search-and-selection-share-visible-state ()
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-match-p "aria-label=\"搜索图谱节点\"" graph))
    (should (string-match-p "id=\"graph-match-status\"" graph))
    (should (string-match-p "id=\"btn-clear-selection\"" graph))
    (should (string-search "var state={query:'',category:'*',selectedId:" graph))
    (should-not (string-search "focusOk" graph))
    (should (string-search
             ".classed('is-dimmed',function(node){return !matches(node);})"
             graph))
    (should (string-search "function clearSelection" graph))
    (should (string-search "event.key==='Escape'" graph))
    (should (string-search "visible.length+' 个匹配节点'" graph))))

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
          (should (string-match-p "搜索标题、分类或标签" html))
          (should (string-match-p "全部笔记 · 按更新时间" html))
          (should (string-match-p "rel=\\\"icon\\\" href=\\\"data:,\\\"" html))
          (should (string-match-p "索引为空" empty))
          (should (string-match-p "\"pages\":\\[\\]" empty)))
      (delete-directory root t))))

(ert-deftest org-museum-index-filters-share-one-url-backed-state ()
  (let* ((root (make-temp-file "org-museum-index-filter-test-" t))
         (org-museum-root-dir root)
         (org-museum--plugin-dir org-museum-test--repo-root)
         (out-file (expand-file-name "exports/html/index.html" root))
         (page (org-museum-test--page
                "alpha" "Alpha" 42 "Sql" '("database") "draft"))
         (html (org-museum--build-index-html
                `(("Sql" . (,page))) "graph.html" out-file)))
    (unwind-protect
        (progn
          (should (string-match-p "data-index-reset" html))
          (should (string-match-p "data-clear-index-filters" html))
          (should (string-match-p "id=\"index-filter-summary\"" html))
          (should (string-match-p
                   "<button type=\"button\" class=\"museum-entry-category\""
                   html))
          (should (string-match-p "aria-live=\"polite\"" html))
          (should (string-match-p
                   "var state={query:'',category:'',status:'all'}" html))
          (should (string-match-p "history.pushState" html))
          (should (string-match-p "addEventListener('popstate'" html))
          (should (string-match-p "params.get('category')" html))
          (should (string-match-p "params.get('status')" html))
          (should (string-match-p "setAttribute('aria-pressed'" html))
          (should (string-match-p
                   (regexp-quote
                    "'.topic-filter[data-category],[data-category-link]'")
                   html))
          (should-not (string-match-p
                       (regexp-quote
                        "querySelectorAll('[data-category],[data-category-link]')")
                       html)))
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
            (should (string-match-p "data-status-filter=\"all\"" html))
            (should (string-match-p "data-status-filter=\"published\"" html))
            (should (string-match-p "data-status-filter=\"draft\"" html))
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
                             '("missing-description")))))
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
            (should-not (org-museum-page-description page))))
      (delete-directory root t))))

(ert-deftest org-museum-health-reports-duplicate-heading-paths-and-legacy-anchors ()
  "Health diagnostics expose migration risks without rewriting source notes."
  (let* ((root (make-temp-file "org-museum-heading-health-test-" t))
         (org-museum-root-dir root)
         (org-museum-scan-dir "pages")
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
            (org-museum--rewrite-org-museum-links (current-buffer) out-file source)
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
            (should (string-match-p "graph-wiki-literal" html))
             (should (string-match-p "graph-copy-status" html))
             (should (string-match-p "rel=\\\"icon\\\" href=\\\"data:,\\\"" html))
             (should (string-match-p "setAttribute('aria-pressed'" html))
            (should (string-match-p "navigator.clipboard" html))
            (should (string-match-p "document.execCommand('copy')" html))
            (should (string-match-p "复制失败，请手动复制" html))
            (should (string-match-p "forceSimulation(nodes)" html))
            (should (string-match-p
                     (regexp-quote ".attr('role','group')") html))
            (should-not (string-match-p
                         (regexp-quote ".attr('role','img')") html))
            (should (string-match-p "forceX(width/2)" html))
            (should (string-match-p "graph-node-neighbour" html))
            (should (string-match-p "isolatedFallback.hidden=false" html))
            (should (string-match-p "renderFallbackList" html))
            (should-not
             (string-match-p
              "if(links.length===0)[[:space:]]*{[^}]*return;" html))))
      (delete-directory root t))))

(ert-deftest org-museum-graph-deduplicates-reciprocal-page-connections ()
  "Mutual page references render as one undirected visual connection."
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
          (org-museum-page-links-to beta) '("alpha")
          (org-museum-page-linked-from beta) '("alpha"))
    (puthash "alpha" alpha pages)
    (puthash "beta" beta pages)
    (let* ((json-array-type 'list)
           (json-object-type 'alist)
           (data (json-read-from-string (org-museum--generate-graph-json)))
           (links (alist-get 'links data))
           (nodes (alist-get 'nodes data)))
      (should (= 1 (length links)))
      (should (equal '("alpha" "beta")
                     (sort (list (alist-get 'source (car links))
                                 (alist-get 'target (car links)))
                           #'string<)))
      (should (equal '(1 1)
                     (sort (mapcar (lambda (node) (alist-get 'degree node)) nodes)
                           #'<))))))

(ert-deftest org-museum-graph-opens-an-article-on-the-first-click ()
  "A mouse click has the same direct-navigation result as Enter."
  (let ((graph (org-museum--build-graph-html
                "{\"nodes\":[],\"links\":[],\"meta\":{}}"
                "resources/org-museum.css" "resources/d3.v7.min.js")))
    (should (string-search
             ".on('click',function(_event,node){openNode(node);})" graph))
    (should (string-search
             "if(event.key==='Enter'){event.preventDefault();openNode(node);}" graph))
    (should-not (string-search ".on('dblclick'" graph))))

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
                (should (= 1 (length links)))
                (should
                 (equal '("alpha" "beta")
                        (sort (list (alist-get 'source (car links))
                                    (alist-get 'target (car links)))
                              #'string<))))
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
              (dolist (needle '("var meta=raw.meta||{}"
                                "new URLSearchParams(location.search)"
                                "orgMuseumThemeUrl(href)"
                                ".alphaDecay(alphaDecay)"
                                "tickCount=0;simulation.alphaTarget(.25)"
                                "tickCount=0;simulation.alpha(.35)"))
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
          (should (string-match-p
                   "<h1 class=\"sr-only\">Org Museum</h1>" html))
          (should (string-match-p
                   (regexp-quote
                    "document.body.classList.toggle('museum-index-filtering',listMode)")
                   html))
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
  (dolist (kind '(home article graph))
    (let ((topbar (org-museum--build-topbar "index.html" kind)))
      (should (= (length (split-string topbar "data-theme-toggle" t)) 2))
      (should (string-match-p
               (regexp-quote "aria-label=\"切换为浅色主题\"") topbar))
      (should-not (string-match-p "aria-pressed=" topbar)))))

(ert-deftest org-museum-article-topbar-exposes-one-drawer-trigger ()
  "Only article pages expose the existing mobile notes drawer."
  (let ((article (org-museum--build-topbar "article.html" 'article)))
    (should (= (length (split-string article "data-drawer-toggle" t)) 2))
    (should (string-match-p "aria-label=\"打开全部笔记\"" article)))
  (let ((runtime (org-museum--script-shell)))
    (should (string-match-p
             (regexp-quote
              "button.setAttribute('aria-label',open?'关闭全部笔记':'打开全部笔记');")
             runtime)))
  (dolist (kind '(home graph))
    (should-not (string-match-p
                 "data-drawer-toggle"
                 (org-museum--build-topbar "index.html" kind)))))

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
                              "readThemeFromUrl"
                              "window.orgMuseumThemeUrl"
                              "data-theme-toggle"
                              "DOMContentLoaded"))
              (goto-char (point-min))
              (should (search-forward needle nil t)))
            (goto-char (point-min))
            (should-not (search-forward "aria-pressed" nil t))))
      (delete-directory root t))))

(ert-deftest org-museum-publish-sync-builds-a-managed-mirror ()
  "Publishing replaces managed output while preserving repository-owned files."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-sync-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (expand-file-name "../published-site" root))
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
              (expand-file-name ".org-museum-publish-manifest.json" root)
            (insert "{\"schemaVersion\":1,"
                    "\"files\":[\".nojekyll\",\"index.html\"]}"))
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

(ert-deftest org-museum-publish-sync-blocks-windows-absolute-paths ()
  "A Windows absolute path aborts before the publish checkout is changed."
  (let* ((root (file-name-as-directory
                (make-temp-file "org-museum-publish-private-test-" t)))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "exports/html")
         (org-museum-publish-directory
          (expand-file-name "../private-publish-site" root))
         (export-root (expand-file-name "exports/html" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pages" export-root) t)
          (make-directory (expand-file-name "resources" export-root) t)
          (with-temp-file (expand-file-name "index.html" export-root)
            (insert "<code>path:C:/private/secret.txt</code>"))
          (with-temp-file (expand-file-name "graph.html" export-root)
            (insert "GRAPH"))
          (cl-letf (((symbol-function 'org-museum-export-all) #'ignore))
            (should-error (org-museum-publish-sync)
                          :type 'org-museum-publish-error))
          (should-not (file-directory-p org-museum-publish-directory)))
      (delete-directory root t)
      (when (file-directory-p org-museum-publish-directory)
        (delete-directory org-museum-publish-directory t)))))

(ert-deftest org-museum-publish-safety-refusal-is-a-user-error ()
  "An expected privacy refusal must not enter the debugger."
  (should (memq 'user-error
                (get 'org-museum-publish-error 'error-conditions))))

(ert-deftest org-museum-publish-privacy-scan-distinguishes-unc-from-javascript ()
  "UNC paths are private, while bundled regular-expression syntax is safe."
  (let ((unc-file (make-temp-file "org-museum-publish-unc-" nil ".js"))
        (drive-file (make-temp-file "org-museum-publish-drive-" nil ".js"))
        (syntax-file (make-temp-file "org-museum-publish-js-" nil ".js")))
    (unwind-protect
        (progn
          (with-temp-file unc-file (insert "open('\\\\server\\share\\note.org')"))
          (with-temp-file drive-file (insert "source:C:/$private/secret.txt"))
          (with-temp-file syntax-file
            (insert "\\\\\\*{2}[^\\n]*? begin:/HTTP\\\\/ ?o:/[%p]"))
          (should (equal (org-museum--publish-privacy-violations
                          (list unc-file drive-file syntax-file))
                         (list unc-file drive-file))))
      (delete-file unc-file)
      (delete-file drive-file)
      (delete-file syntax-file))))

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
          (expand-file-name "../rollback-publish-site" root))
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
          "{\"schemaVersion\":1,\"files\":[\".nojekyll\",\"index.html\"]}")
         calls)
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
          (with-current-buffer "*Org Museum Publish*"
            (should (string-match-p "0123456789abcdef" (buffer-string)))
            (should (string-match-p
                     "https://github.com/example/org-notes"
                     (buffer-string)))))
      (delete-directory root t))))

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
          (when (get-buffer "*Org Museum Publish*")
            (kill-buffer "*Org Museum Publish*"))
          (cl-letf (((symbol-function 'executable-find) (lambda (_) t))
                    ((symbol-function 'process-file)
                     (lambda (_program _in destination _display &rest _args)
                       (with-current-buffer destination (insert payload))
                       0)))
            (should (equal (cdr (org-museum--publish-run "git" '("status")))
                           payload)))
          (with-current-buffer "*Org Museum Publish*"
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
             "(\"p\" \"Sync Publish Site\" org-museum-publish-sync)" nil t))
    (should (search-forward
             "(\"P\" \"Deploy to GitHub\"  org-museum-publish-deploy)"
             nil t))))

(provide 'org-museum-test)

;;; org-museum-test.el ends here
