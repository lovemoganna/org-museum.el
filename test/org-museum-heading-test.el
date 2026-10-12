;;; org-museum-heading-test.el --- Outline colour identity tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)

(ert-deftest org-museum-headings-preserve-deep-levels-without-changing-export ()
  (let* ((source (concat "#+OPTIONS: H:3 num:nil\n"
                         "* One\n** Two\n*** Three\n**** Four\n"
                         "***** Five\n****** Six\n******* Seven\n"
                         "Body with [[https://example.com][a link]].\n- ordinary item\n"))
         (plain (org-export-string-as source 'html t))
         (museum (org-export-string-as source 'org-museum-html t)))
    (dotimes (index 7)
      (should (string-match-p
               (format "class=\"museum-heading-level-%d\"" (1+ index)) museum)))
    (let ((start 0))
      (while (string-match "href=\"#\\(org[0-9a-f]+\\)\"" museum start)
        (let ((reference (match-string 1 museum)))
          (setq start (match-end 0))
          (should (string-match-p (concat "id=\"" reference "\"") museum)))))
    ;; Only title spans may differ; lists, links, IDs and body stay intact.
    (let ((stripped (replace-regexp-in-string
                     "<span class=\"museum-heading-level-[1-8]\">\\([^<]*\\)</span>"
                     "\\1" museum)))
      ;; Org assigns random references for each separate export.
      (setq plain (replace-regexp-in-string "org[0-9a-f]+" "orgREF" plain)
            stripped (replace-regexp-in-string "org[0-9a-f]+" "orgREF" stripped))
      (should (equal plain stripped)))))

(ert-deftest org-museum-headings-retain-custom-title-formatting ()
  (let* ((org-html-format-headline-function
          (lambda (_todo _type _priority text _tags _info)
            (concat "<em>" text "</em>")))
         (html (org-export-string-as "* Heading\nBody.\n" 'org-museum-html t)))
    (should (string-match-p
             "<span class=\"museum-heading-level-1\"><em>Heading</em></span>" html))))

(provide 'org-museum-heading-test)
