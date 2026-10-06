;;; org-museum-media-test.el --- Media rendering regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)

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
