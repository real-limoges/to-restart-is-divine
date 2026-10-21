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

;;; eval thread's dynamic state (but frozen).
;;; *EVAL-STATE* isn't assigned and only rebound with LET on the eval thread
;;; so it has a definite lifecycle. Everything else is an argument.

(defstruct (eval-state (:constructor make-eval-state (&key levels top-level evaluating))
                       (:copier nil))
  (levels '() :read-only t)
  (top-level nil :read-only t)
  (evaluating nil :read-only t))

(defvar *eval-state* (make-eval-state)
  "Eval thread's state. Global value is idle. No levels and not evaluating")

(defun eval-state-with (state &key (levels (eval-state-levels state))
                                (top-level (eval-state-top-level state))
                                (evaluating (eval-state-evaluating state)))
  "Copy of STATE with the given fields replaced"
  (make-eval-state :levels levels :top-level top-level :evaluating evaluating))

;; (defvar *agent*)
;; (defvar *levels*)                       ; open debugger levels, newest first
;; (defvar *top-level*)                    ; ABORT restart returns to top level
;; (defvar *evaluating*)                   ; true when visitor code runs so an interupt can open a level

(define-condition interrupted (condition)
  ()
  (:report "Interrupted from the page"))

(defconstant +backtrace-frames+ 30
  "Most frames :debug message brings")

(defun call-with-visitor-repl (output function)
  (let* ((terminal (make-two-way-stream (make-stream-input-stream "") output))
         (*package* (find-package "CL-USER"))
         (*standard-output* output)
         (*error-output* output)
         (*trace-output* output)
         (*terminal-io* terminal)
         (*standard-input* terminal)
         (*query-io* terminal)
         (*debug-io* terminal)
         (- nil) (+ nil) (++ nil) (+++ nil)
         (* nil) (** nil) (*** nil)
         (/ nil) (// nil) (/// nil))
    (funcall function)))

(defun eval-loop (agent)
  "The eval thread which serves the inbox at the top level, forever"
  (let ((output (make-forwarding-stream (lambda (text) (send agent (list :output text)))))
        (*eval-state* (make-evalstate)))
    (call-with-visitor-repl
     output
     (lambda ()
       (call-with-debugger (lambda (condition) (enter-debugger agent condition))
                           (lambda ()
                             (loop (serve-top-level agent))))))))

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

(defun evaluate-form (form)
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

;; Debugger starts here

(defun enter-debugger (agent condition)
  "CONDITION is the new debugger level, and keep serving the inbox until
a restart."
  (let* ((id (agent-next-id agent))
         (restarts (visible-restarts condition))
         (levels (cons (list id restarts) (eval-state-levels *eval-state*)))
         (*eval-state* (eval-state-with *eval-state* :levels levels :evaluating nil)))
    (setf (agent-next-id agent) (1+ id))
    (finish-output *standard-output*)
    (send agent (list :debug
                      :id id
                      :level (length *levels*)
                      :type (type-name condition)
                      :report (printed #'princ-to-string condition)
                      :restarts (loop for restart in restarts
                                      for index from 0
                                      collect (list index
                                                    (restart-label-name restart)
                                                    (printed #'princ-to-string restart)))
                      :backtrace (backtrace)))
    (unwind-protect (serve-level agent)
      (send agent (list :debug-done id)))))

(defun serve-level (agent)
  "Take messsages from inbox inside newest level until a restart"
  (loop
    (let ((message (mailbox-receive (agent-inbox agent))))
      (ecase (first message)
        (:eval (evaluate agent (second message)))
        (:invoke-restart (destructuring-bind (id index) (rest message)
                           (invoke-chosen-restart id index)))))))

(defun invoke-chosen-restart (id index)
  "Invoke restart INDEX of open level ID. Unknown indexes or levels are ignored"
  (let* ((level (find id (eval-state-levels *eval-state*) :key #'first))
         (restarts (second level)))
    (when (and level (typep index `(integer 0 (,(length restarts)))))
      (invoke-restart-interactively (nth index restarts)))))

(defun visible-restarts (condition)
  "CONDITION's restarts (from the inside) ending at agent's top-level ABORT.
Restarts beyond belong to the thread which would end the eval thread"
  (let* ((restarts (compute-restarts condition))
         (end (position (eval-state-top-level *eval-state*) restarts)))
    (if end
        (subseq restarts 0 (1+ end))
        restarts)))

(defun restart-label-name (restart)
  "RESTART's name as string (empty if anon)"
  (let ((name (restart-name restart)))
    (if name (symbol-name name) "")))

(defun type-name (condition)
  "CONDITION's type, package-qualified unless its in CL-USER"
  (with-standard-io-syntax
    (prin1-to-string (type-of condition))))

(defun printed (printer object)
  "OBJECT printed by PRINTER, or a note if there's an error"
  (handler-case (funcall printer object)
    (error () "#<error while printing>")))

(defun backtrace ()
  "Newest frames printed and numbered down to agent's EVALUATE-FORM"
  (let ((*print-length* 10)
        (*print-level* 4)
        (*print-circle* t))
    (loop for cal in (backtrace-calls 'evaluate-form +backtrace-frames+)
          for index from 0
          collect (format nil "~D: ~A" index (printed #'prin1-to-string call)))))

;; Reader Thread

(defun interrupt-evaluation (agent)
  "Open debugger level in the eval thread when running visitor code"
  (interrupt (agent-eval-thread agent)
             (lambda ()
               (when (eval-state-evaluating *eval-state*)
                 (with-simple-restart (continue "Resume the interrupted eval")
                   (invoke-debugger (make-condition 'interrupted)))))))


(defun reader-loop (agent)
  "Pump messages from gateway until the socket closes, then end eval thread"
  (unwind-protect
       (handler-case
           (loop for message = (read-message (agent-stream agent))
                 while message
                 do (case (first message)
                      ((:eval :invoke-restart) (mailbox-send (agent-inbox agent) message))
                      (:interrupt (interrupt-evaluation agent))
                      (:ping (send agent '(:pong)))))
         (error (condition)
           (format *error-output* "~&;; Agent reader stopped: ~A~%" condition)))
    (kill-thread (agent-eval-thread agent))
    (close (agent-stream agent) :abort t)))

(defun start-agent (path)
  "Connect to gateway listening on PATH, send :ready and start both threads. Return the agent"
  (let ((agent (%make-agent (connect-unix-socket path))))
    (setf (agent-eval-thread agent) (spawn "agent eval" (lambda () (eval-loop agent))))
    (send agent '(:ready))
    (setf (agent-reader-thread agent) (spawn "agent reader" (lambda () (reader-loop agent))))
    agent))

(defun wait-for-agent (agent)
  "Return once AGENT's gateway has hung up and *both* threads have ended"
  (wait-for-thread (agent-reader-thread agent))
  (wait-for-thread (agent-eval-thread agent)))

(defun run-agent (path)
  "Serve gateway at PATH until it hands up. Entry point for agent"
  (wait-for-agent (start-agent path))
  (exit-process))
