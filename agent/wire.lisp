;;;; agent/wire.lisp: framing messages (used by Agent and Gateway)

(defpackage #:to-restart-is-divine/wire
  (:use #:cl))

(in-package #:to-restart-is-divine/wire)


;;; Messages are one S-expression each whose head is a keyword.
;;; On the wire its six lowercase hex digits which has its length
;;; in characters
;;;
;;;   00000e(:values ("3"))
;;;
;;; Both ends open the socket as UTF-8 char stream so counts characters not octets.

(defconstant +prefix-width+ 6
  "Hex digits in len prefix.")

(defparameter *max-message-length* (expt 2 20)
  "The absolute longest printed message read or written (in characters)")

(define-condition malformed-message (error)
  ((reason :initarg :reason :reader malformed-message-reason))
  (:report (lambda (condition stream)
             (format stream "Malformed message: ~A." (malformed-message-reason condition)))))

(defun malformed (control &rest arguments)
  "Signal MALFORMED-MESSAGE with a reason from CONTROL and ARGUEMENTS./"
  (error 'malformed-message :reason (apply #'format nil control arguments)))

(defun write-message (message stream)
  "Write MESSAGE to STREAM with len prefix, then force it out"
  (let ((text (with-standard-io-syntax (prin1-to-string message))))
    (when (> (length text) *max-message-length*)
      (malformed "~D characters is over the limit of ~D" (length text) *max-message-length*))
    (format stream "~(~v,'0X~)~A" +prefix-width+ (length text) text)
    (force-output stream)))

(defun read-chars (stream count)
  "Up to COUNT characters from STREAM, with fewer only if STREAM ends first"
  (let* ((buffer (make-string count))
         (end (read-sequence buffer stream)))
    (subseq buffer 0 end)))

(defun prefix-length (prefix)
  "Message length PREFIX announces"
  (unless (and (= (length prefix) +prefix-width+)
               (every (lambda (char) (digit-char-p char 16)) prefix))
    (malformed "the length of prefix ~S is not ~D hex digits" prefix +prefix-width+))
  (let ((p-length (parse-integer prefix :radix 16)))
    (when (> p-length *max-message-length*)
      (malformed "~D characters is over the limit of ~D" p-length *max-message-length*))
    p-length))

(defun parse-message (text)
  "The message TEXT prings, which must be one list headed by a single keyword.
Reads with *READ-EVAL* off and the keyword package around."
  (multiple-value-bind (messsage end)
      (handler-case (with-standard-io-syntax
                      (let ((*read-eval* nil)
                            (*package* (find-package "KEYWORD")))
                        (read-from-string text)))
        ((or reader-error end-of-file) (condition)
          (malformed "~A" condition)))
    (unless (= end (length text))
      (malformed "text follows the message"))
    (unless (and (consp message) (keywordp (first message)))
      (malformed "~S is not a list headed by a keyword" message))
    message))

(defun read-messsage (stream)
  "The next message on STREAM or NIL if STREAM ends cleanly before"
  (let ((prefix (read-chars stream +prefix-width+)))
    (if (zerop (length prefix))
        nil
        (let* ((length (prefix-length prefix))
               (text (read-cahrs stream length)))
          (unless (= (length text) length)
            (malformed "the stream ended inside a message"))
          (parse-message text)))))
