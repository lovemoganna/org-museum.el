;;; org-museum-http-security-test.el --- Local HTTP boundaries -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-museum)
(require 'org-museum-ai-web)

(defun org-museum-http-test--exchange (chunks)
  "Feed wire CHUNKS through the real filter, without opening a socket."
  (let ((properties (make-hash-table)) (live t) replies dispatched
        (org-museum--curation-server-port 49152))
    (cl-letf (((symbol-function 'process-get) (lambda (_ key) (gethash key properties)))
              ((symbol-function 'process-put) (lambda (_ key value) (puthash key value properties)))
              ((symbol-function 'process-live-p) (lambda (_) live))
              ((symbol-function 'delete-process) (lambda (_) (setq live nil)))
              ((symbol-function 'process-send-string) (lambda (_ value) (push value replies)))
              ((symbol-function 'org-museum--curation-dispatch-http)
               (lambda (method path headers body)
                 (push (list method path headers body) dispatched)
                 (org-museum--curation-http-response 200 "{}"))))
      (dolist (chunk chunks) (when live (org-museum--curation-server-filter 'fixture chunk))))
    (list :reply (car replies) :dispatched dispatched :live live)))

(ert-deftest org-museum-http-rejects-non-loopback-host-before-serving-files ()
  (dolist (host '("attacker.invalid:49152" "127.0.0.1:80" "127.0.0.1:49152@attacker.invalid" ""))
    (let ((result (org-museum-http-test--exchange
                   (list (format "GET /index.html HTTP/1.1\r\nHost: %s\r\n\r\n" host)))))
      (should-not (plist-get result :dispatched))
      (should (string-prefix-p "HTTP/1.1 403" (plist-get result :reply))))))

(ert-deftest org-museum-http-rejects-ambiguous-or-invalid-framing ()
  (dolist (headers '("Content-Length: -1\r\n" "Content-Length: abc\r\n"
                     "Content-Length: 3garbage\r\n" "Content-Length: 0\r\nContent-Length: 4\r\n"
                     "Transfer-Encoding: chunked\r\n" "Host: evil.invalid\r\n"))
    (let ((result (org-museum-http-test--exchange
                   (list (concat "POST /api/v1/preview HTTP/1.1\r\nHost: localhost:49152\r\n"
                                 headers "\r\n{}")))))
      (should-not (plist-get result :dispatched))
      (should (string-prefix-p "HTTP/1.1 400" (plist-get result :reply))))))

(ert-deftest org-museum-http-bounds-headers-before-body-arrives ()
  (let ((result (org-museum-http-test--exchange
                 (list (concat "GET / HTTP/1.1\r\nHost: localhost:49152\r\nX-Pad: "
                               (make-string 8200 ?x))))))
    (should-not (plist-get result :live))
    (should (string-prefix-p "HTTP/1.1 413" (plist-get result :reply)))))

(ert-deftest org-museum-http-keeps-valid-fragmented-utf8-body ()
  (let* ((body (encode-coding-string "{\"title\":\"你好\"}" 'utf-8 t))
         (head (format "POST /api/v1/preview HTTP/1.1\r\nHost: localhost:49152\r\nContent-Length: %d\r\n\r\n"
                       (string-bytes body)))
         (result (org-museum-http-test--exchange
                  (list (concat head (substring body 0 5)) (substring body 5)))))
    (should (= 1 (length (plist-get result :dispatched))))
    (should (equal body (nth 3 (car (plist-get result :dispatched)))))
    (should (string-prefix-p "HTTP/1.1 200" (plist-get result :reply)))))

(ert-deftest org-museum-http-json-requires-one-complete-object ()
  (dolist (body '("[]" "null" "42" "{} {}" "{\"pageId\":\"a\"}garbage"))
    (should-error (org-museum--curation-json-read body) :type 'org-museum-curation-error)
    (should-error (org-museum-ai-web--request body) :type 'org-museum-curation-error))
  (should (equal (org-museum--curation-json-read " {\"pageId\":\"a\"} \n")
                 '(("pageId" . "a"))))
  (should (equal (org-museum-ai-web--request " {\"pageId\":\"a\"} \n")
                 '((pageId . "a")))))

(provide 'org-museum-http-security-test)
