;;;; test/wire-tests.lisp

(in-package #:to-restart-is-divine/tests)

(defvar *never-read*)

(def-suite wire :in divine-tests)
(in-suite wire)

(defun with-prefix (message)
  "MESSAGE as WRITE-MESSAGE puts it on the wire"
  (with-output-to-string (out)
    (w:write-message message out)))

(defun without-prefix (text)
  "Message READ-MESSAGE finds at the start of TEXT"
  (with-input-from-string (in text)
    (w:read-message in)))

(defun raw-prefixed (text)
  "TEXT for a correct length prefix"
  (format nil "~(~6,'0X~)~A" (length text) text))

;;; The actual tests

(test catalog-round-trips
  (dolist (message '((:eval "(car 5)") (:invoke-restart 3 0) (:interrupt) (:ping)
                     (:ready) (:output "λ \"quoted\" \\ back") (:values ("3" "NIL")) (:values ())
                     (:level-opened :id 1 :depth 1 :type "TYPE-ERROR" :report "r"
                             :restarts ((0 "ABORT" "Return to top level.")) :backtrace ("0: (CAR 5)"))
                     (:level-closed 1) (:pong)))
    (is (equal message (without-prefix (with-prefix message))))))

(test prefix-counts-characters-in-lowercase-hex
  (is (equal "000007(:ping)" (with-prefix '(:ping))))
  (is (equal "00000d(:output \"λ\")" (with-prefix '(:output "λ")))))

(test empty-stream-is-nil
  (is (null (without-prefix ""))))

(test truncated-message-is-malformed
  (signals w:malformed-message (without-prefix "000010(:ping)"))
  (signals w:malformed-message (without-prefix "0000")))

(test read-eval-is-refused
  (signals w:malformed-message (without-prefix (raw-prefixed "(:ping #.(setf *never-read* t))")))
  (is (not (boundp '*never-read*))))

(test oversized-prefix-is-refused-before-the-body
  (signals w:malformed-message (without-prefix "ffffff")))

(test text-after-the-form-is-refused
  (signals w:malformed-message (without-prefix (raw-prefixed "(:ping)(:pong)"))))

(test kind-must-be-a-keyword
  (signals w:malformed-message (without-prefix (raw-prefixed "(\"x\")")))
  (signals w:malformed-message (without-prefix (raw-prefixed "42"))))

(test oversized-message-is-not-written
  (let ((w:*max-message-length* 10))
    (signals w:malformed-message (with-prefix '(:output "more than ten characters")))))
