;;; org-museum-media-test.el --- Media rendering regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)

(ert-deftest org-museum-media-recovers-hash-bound-html-results ()
  "Saved generated HTML must publish its real image and reject wrong content."
  (let* ((root (make-temp-file "museum-embedded-media-" t))
         (org-museum-root-dir root)
         (org-museum-shared-export-dir "dist")
         (org-museum--asset-registry (make-hash-table :test #'equal))
         (org-museum--page-assets (make-hash-table :test #'equal))
         (org-museum--index nil)
         (image (expand-file-name "diagram.png" root))
         (source (expand-file-name "note.org" root))
         (out (expand-file-name "dist/pages/note.html" root)))
    (unwind-protect
        (progn
          (with-temp-file image
            (set-buffer-multibyte nil)
            (insert (base64-decode-string "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVZkAAAAASUVORK5CYII=")))
          (let* ((hash (org-museum--file-content-hash image))
                 (snippet (format "@@html:<figure class=\"museum-asset museum-asset-image\" data-asset-id=\"%s\"><img src=\"../../assets/%s.png\" alt=\"Original &amp; label\"></figure>@@\n" hash hash)))
            (with-temp-file source (insert snippet))
            (org-museum--preflight-page-assets source)
            (should (gethash hash org-museum--asset-registry))
            (org-museum--publish-assets)
            (should (file-exists-p (expand-file-name (concat "dist/assets/" hash ".png") root)))
            (with-temp-buffer
              (insert-file-contents source)
              (should (equal snippet (buffer-string))))
            (with-temp-buffer
              (insert snippet)
              (delay-mode-hooks (org-mode))
              (org-museum--prepare-page-assets (current-buffer) source out)
              (should (string-search "../assets/" (buffer-string)))
              (should (string-search "alt=\"Original &amp; label\"" (buffer-string))))
            (with-temp-buffer
              (insert "* Hidden :noexport:\n" (replace-regexp-in-string hash (make-string 64 ?0) snippet t t))
              (delay-mode-hooks (org-mode))
              (org-museum--prepare-page-assets (current-buffer) source out))
            (with-temp-buffer
              (insert (replace-regexp-in-string hash (make-string 64 ?0) snippet t t))
              (delay-mode-hooks (org-mode))
              (should-error (org-museum--prepare-page-assets (current-buffer) source out)
                            :type 'org-museum-asset-error))))
      (delete-directory root t))))

(ert-deftest org-museum-media-images-reserve-intrinsic-size-and-escape-caption ()
  (let* ((asset (make-org-museum-asset
                 :id "image" :filename "chart.png" :mime "image/png"
                 :kind 'image :published-url "assets/chart.png"
                 :width 1600 :height 900))
         (html (org-museum--asset-render-html asset "dist/pages/media.html"
                                              "图表 <A> & B")))
    (should (string-search "width=\"1600\" height=\"900\"" html))
    (should (string-search "<figcaption>图表 &lt;A&gt; &amp; B</figcaption>" html))
    (should (string-search "data-lightbox" html))
    (should-not (string-search "<figcaption>" (org-museum--asset-render-html
                                               asset "dist/pages/media.html" nil)))
    (setf (org-museum-asset-width asset) nil)
    (should-not (string-search "width=" (org-museum--asset-render-html
                                         asset "dist/pages/media.html" nil)))))

(ert-deftest org-museum-media-players-have-names-and-independent-source-links ()
  (dolist (kind '(video audio))
    (let* ((asset (make-org-museum-asset
                   :id "player" :filename "sample&clip.webm" :kind kind
                   :mime (if (eq kind 'video) "video/webm" "audio/ogg")
                   :published-url "assets/sample&clip.webm"))
           (html (org-museum--asset-render-html
                  asset "dist/pages/media.html" "录制 \"片段\"")))
      (with-temp-buffer
        (insert html)
        (goto-char (point-min))
        (should (search-forward "aria-label=\"录制 &quot;片段&quot;\"" nil t)))
      (should (string-search "preload=\"none\"" html))
      (should (string-search "museum-asset-caption" html))
      (should (string-match-p "<a href=\"[^\"]*sample&amp;clip.webm\"" html))
      (should (string-search (if (eq kind 'video) "打开视频源文件" "打开音频源文件") html))
      (when (eq kind 'video) (should (string-search "playsinline" html)))
      (let ((compact (org-museum--asset-render-html asset "dist/pages/media.html" nil t)))
        (should (string-search "download=" compact))
        (should-not (string-search "<figcaption" compact))))))

(provide 'org-museum-media-test)
