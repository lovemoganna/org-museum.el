(require 'ert)
(require 'org-museum)

(ert-deftest org-museum-publish-manifest-includes-assets-and-rejects-unlisted-assets ()
  "Asset exports deploy with valid hashes; additional files still fail closed."
  (let ((root (make-temp-file "museum-publish-assets-" t))
        (org-museum-assets-subdir "media"))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "media" root))
          (with-temp-file (expand-file-name "assets.json" root) (insert "{}"))
          (with-temp-file (expand-file-name "media/chart.svg" root) (insert "<svg/>"))
          (org-museum--publish-write-manifest root '("assets.json" "media/chart.svg"))
          (let ((manifest (org-museum--publish-read-manifest root)))
            (org-museum--publish-validate-manifest-integrity root manifest)
            (org-museum--publish-validate-ready-candidate root (plist-get manifest :files))
            (with-temp-file (expand-file-name "media/unlisted.svg" root) (insert "<svg/>"))
            (should-error (org-museum--publish-validate-manifest-integrity root manifest)
                          :type 'org-museum-publish-error)
            (should-error (org-museum--publish-validate-ready-candidate root (plist-get manifest :files))
                          :type 'org-museum-publish-error)))
      (delete-directory root t))))
