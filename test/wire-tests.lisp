;;;; test/wire-tests.lisp

(in-package #:to-restart-is-divine/tests)

(defvar *never-read*)

(def-suite wire :in divine-tests)
(in-suite wire)

(defun framed (message)
  "MESSAGE as WRITE-MESSAGE puts it on the wire"
  (with-output-to-string (out)
    (w:write-message message out)))

(defun unframed (text)
  "Message READ-MESSAGE finds at the start of TEXT"
  (with-input-from-string (in text)
    (w:read-message in)))

(defun raw-frame (text)
  "TEXT for a correct length prefix"
  (format nil "~(~6,'0X~)~A" (length text) text))

;;; The actual tests

(test catalog-round-trips
  (dolist (message '((:eval "(car 5)") (:invoke-restart 3 0) (:interrupt) (:ping)
                     (:ready) (:output "λ \"quoted\" \\ back") (:values ("3" "NIL")) (:values ())
                     (:debug :id 1 :level 1 :type "TYPE-ERROR" :report "r"
                             :restarts ((0 "ABORT" "Return to the top level.")) :backtrace ("0: (CAR 5)"))
                     (:debug-done 1) (:pong)))
    (is (equal message (unframed (framed message))))))

(test prefix-counts-characters-in-lowercase-hex
  (is (equal "000007(:ping)" (framed '(:ping))))
  (is (equal "00000d(:output \"λ\")" (framed '(:output "λ")))))

(test empty-stream-is-nil
  (is (null (unframed ""))))

(test truncated-message-is-malformed
  (signals w:malformed-message (unframed "000010(:ping)"))
  (signals w:malformed-message (unframed "0000")))

(test read-eval-is-refused
  (signals w:malformed-message (unframed (raw-frame "(:ping #.(setf *never-read* t))")))
  (is (not (boundp '*never-read*))))

(test oversized-prefix-is-refused-before-the-body
  (signals w:malformed-message (unframed "ffffff")))

(test text-after-the-from-is-refused
  (signals w:malformed-message (unframed (raw-frame "(:ping)(:pong)"))))

(test head-must-be-a-keyword
  (signals w:malformed-message (unframed (raw-frame "(\"x\")")))
  (signals w:malformed-message (unframed (raw-frame "42"))))

(test oversized-message-is-not-written
  (let ((w:*max-message-length* 10))
    (signals w:malformed-message (framed '(:output "more than ten characters")))))
