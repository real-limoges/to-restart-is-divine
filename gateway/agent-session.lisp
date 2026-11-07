;;;; gateway/agent-session.lisp: A session backed by a real agent

(in-package #:to-restart-is-divine/gateway)

;;; Agent messages are already in the event shapes dictated by session.lisp
;;; They pass to the handler unchange. :pong is not an event

(defclass agent-session (session)
  ((link :initarg :link :reader session-link)
   (handler :initarg :handler :reader session-handler)
   (send-lock :initform (sb-thread:make-mutex :name "agent session send") :reader session-send-lock)
   (closed :initform nil :accessor session-closed-p)
   (reader :accessor session-reader))
  (:documentation "A session on one agent - it's reached over its link"))

(defun make-local-agent-session (handler)
  "A session on a fresh agent in a child SBCL. It reports to HANDLER"
  (let ((session (make-instance 'agent-session :link (ln:open-local-agent) :handler handler)))
    (setf (session-reader session)
          (sb-thread:make-thread (lambda () (pump-events session)) :name "agent session reader"))
    session))

(defun pump-events (session)
  "Hand each agent message to the handler until the agent hands up"
  (handler-case
      (loop for message = (w:read-message (ln:link-stream (session-link session)))
            while message
            unless (eq (first message) :pong)
              do (deliver session message))
    (error (condition)
      (unless (session-closed-p session)
        (format *error-output* "~&;; Agent session reader stopped: ~A~%" condition)))))

(defun deliver (session event)
  "Call the handler with EVENT (unless SESSION is closed). Handler error is logged and not fatal"
  (unless (session-closed-p session)
    (handler-case (funcall (session-handler session) event)
      (error (condition)
        (format *error-output* "~&;; Event handler failed on ~S: ~A~%" (first event) condition)))))

(defun send-to-agent (session message)
  "Write MESSAGE to SESSION's agent unless SESSION is closed"
  (sb-thread:with-mutex ((session-send-lock session))
    (unless (session-closed-p session)
      (w:write-message message (ln:link-stream (session-link session))))))

(defmethod session-eval ((session agent-session) text)
  (send-to-agent session (list :eval text)))

(defmethod session-invoke-restart ((session agent-session) id index)
  (send-to-agent session (list :invoke-restart id index)))

(defmethod session-interrupt ((session agent-session))
  (send-to-agent session (list :interrupt)))

(defmethod session-close ((session agent-session))
  (sb-thread:with-mutex ((session-send-lock session))
    (setf (session-closed-p session) t))
  (ln:close-link (session-link session))
  (sb-thread:join-thread (session-reader session) :default nil))
