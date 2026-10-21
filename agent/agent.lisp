;;;; agent/agent.lisp: featuring REPL, debugger, and the message pump

(in-package #:to-restart-is-divine/agent)

;;; Each agent gets 2 threads. Reader reads every message from the gateway
;;; It answers :ping itself, turns :interrupt into an interrupt of the eval
;;; thread, and queues :eval and :invoke-restart in the inbox.
;;; Eval thread takes messages from the inbox (wherever) and sends
;;; everythign else to the gateway.

(defstruct (agent (:constructor %make-agent (stream)))
  (stream nil :read-only t)
  (send-lock (make-lock "agent send") :read-only t)
  (connected t)
  (inbox (make-mailbox) :read-only t)
  (next-id 1)
  eval-thread
  reader-thread)

(defun send (agent message)
  "Send MESSAGE to the gateway. After a failed write, sending does nothing"
  (call-with-lock (agent-send-lock agent)
                  (lambda ()
                    (when (agent-connected agent)
                      (handler-case (write-message message (agent-stream agent))
                        (stream-error ()
                          (setf (agent-connected agent) nil)))))))

;; eval thread's state

(defvar *agent*)
(defvar *levels*)                       ; open debugger levels, newest first
(defvar *top-level*)                    ; ABORT restart returns to top level
(defvar *evaluating*)                   ; true when visitor code runs so an interupt can open a level

(define-condition interrupted (condition)
  ()
  (:report "Interrupted from the page"))

(defconstant +backtrace-frames+ 30
  "Most frames :debug message brings")

(defun eval-loop (agent)
  (let* ((output (make-forwarding-stream (lambda (text) (send agent (list :output text)))))
         (terminal (make-two-way-stream (make-stream-input-stream "") output))
         (*agent* agent)
         (*levels* '())
         (*top-level* nil)
         (*evaluating* nil)
         (*package* (find-package "CL-USER"))
         (*standard-output* output)
         (*error-output* output)
         (*trace-output* output)
         (*terminal-io* terminal)
         (*query-io* terminal)
         (*debug-io* terminal)
         (- nil) (+ nil) (++ nil) (+++ nil)
         (* nil) (** nil) (*** nil)
         (/ nil) (// nil) (/// nil))
    (call-with-debugger #'enter-debugger
                        (lambda ()
                          (loop (serve-top-level agent))))))

(defun serve-top-level (agent)
  "Take a message from the inbox at the top level. If the level is gone
then it's ignored"
  (let ((message (mailbox-receive (agent-inbox agent))))
    (when (eq (first message) :eval)
      (with-simple-restart (abort "Return to top level")
        (let ((*top-level* (find 'abort (compute-restarts) :key #'restart-name)))
          (evaluate agent (second message)))))))

(defun evaluate (agent text)
  "Read + evaluate each form in TEXT, sending printed values"
  (let ((*evaluating* t))
    (with-input-from-string (in text)
      (loop for form = (read in nil in)
            until (eq form in)
            do (setf - form)
               (let ((values (evaluate-form form)))
                 (remember form values)
                 (finish-output *standard-output*)
                 (send agent (list :values (print-values values))))))))

(defun print-values (values)
  "Each of VALUES printed with PRIN1. Circular stuff is shown with #n= label.
Long or deep structures are cut short unless visitor has set their own limits"
  (let ((*print-circle* t)
        (*print-length* (or *print-length* 100))
        (*print-level* (or *print-level* 10)))
    (mapcar #'prin1-to-string values)))

(defun evaluate-formj (form)
  "FORM's values. A RETRY restart evaluates FORM again from the start."
  (loop
    (restart-case (return (multiple-value-list (eval form)))
      (retry ()
        :report "Evaluate the form again."))))

(defun remember (form values)
  "Shift the REPL variables after FORM returned VALUES"
  (setf +++ ++ ++ + + form
        /// // // / / values
        *** ** ** * * (first values)))
