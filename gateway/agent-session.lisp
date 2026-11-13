;;;; gateway/agent-session.lisp: A session backed by a real agent

(in-package #:to-restart-is-divine/gateway)

;;; Agent messages are already in the event shapes session.lisp lists, so
;;; they pass to the receiver unchanged. :pong is not an event

(defclass agent-session (session)
  ((link :initarg :link :reader agent-session-link)
   (receiver :initarg :receiver :reader session-receiver)
   (send-lock :initform (sb-thread:make-mutex :name "agent session send") :reader agent-session-send-lock)
   (closed :initform nil :accessor agent-session-closed-p)
   (event-thread :accessor agent-session-event-thread))
  (:documentation "A session on one agent, reached over its link"))

(defun start-agent-session (receiver)
  "A session on a fresh agent in its own SBCL process. It reports to RECEIVER"
  (let ((session (make-instance 'agent-session :link (ln:open-agent-process) :receiver receiver)))
    (setf (agent-session-event-thread session)
          (sb-thread:make-thread (lambda () (event-loop session)) :name "agent session events"))
    session))

(defun event-loop (session)
  "Hand each agent message to the receiver until the agent hangs up"
  (handler-case
      (loop for message = (w:read-message (ln:link-stream (agent-session-link session)))
            while message
            unless (eq (first message) :pong)
              do (deliver session message))
    (error (condition)
      (unless (agent-session-closed-p session)
        (format *error-output* "~&;; Agent session event thread stopped: ~A~%" condition)))))

(defun deliver (session event)
  "Call the receiver with EVENT (unless SESSION is closed). A receiver error is logged and not fatal"
  (unless (agent-session-closed-p session)
    (handler-case (funcall (session-receiver session) event)
      (error (condition)
        (format *error-output* "~&;; Event receiver failed on ~S: ~A~%" (first event) condition)))))

(defun send-to-agent (session message)
  "Write MESSAGE to SESSION's agent unless SESSION is closed"
  (sb-thread:with-mutex ((agent-session-send-lock session))
    (unless (agent-session-closed-p session)
      (w:write-message message (ln:link-stream (agent-session-link session))))))

(defmethod session-eval ((session agent-session) text)
  (send-to-agent session (list :eval text)))

(defmethod session-invoke-restart ((session agent-session) id index)
  (send-to-agent session (list :invoke-restart id index)))

(defmethod session-interrupt ((session agent-session))
  (send-to-agent session (list :interrupt)))

(defmethod session-close ((session agent-session))
  (sb-thread:with-mutex ((agent-session-send-lock session))
    (setf (agent-session-closed-p session) t))
  (ln:close-link (agent-session-link session))
  (sb-thread:join-thread (agent-session-event-thread session) :default nil))
