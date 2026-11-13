;;;; test/fake-session.lisp: a scripted session that never evals anything

(in-package #:to-restart-is-divine/tests)

(defstruct (fake-script (:constructor make-fake-script (&key replies errors restarts))
                        (:copier nil))
  (replies '() :read-only t)
  (errors '() :read-only t)
  (restarts '() :read-only t))

(defparameter *fake-script*
  (make-fake-script
   :replies '(("(+ 1 2)" (:values ("3")))
              ("(values)" (:values ()))
              ("(print 'hello)" (:output "
HELLO ") (:values ("HELLO"))))
   :errors '(("(car 5)" "TYPE-ERROR" "The value
  5
is not of type
  LIST")
             ("(/ 1 0)" "DIVISION-BY-ZERO" "arithmetic error DIVISION-BY-ZERO signalled"))
   :restarts '((0 "RETRY" "Evaluate the form again.")
               (1 "ABORT" "Return to top level.")))
  "What the fake answers, the levels it opens, and the restarts each level offers.")

(defun fake-abort-index (script)
  "The index of ABORT in SCRIPT's restart list"
  (first (find "ABORT" (fake-script-restarts script) :key #'second :test #'string=)))

(defclass fake-session (g:session)
  ((receiver :initarg :receiver :reader fake-receiver)
   (next-id :initform 1 :accessor fake-next-id)
   (open-level-ids :initform '() :accessor fake-open-level-ids))
  (:documentation "A session that answers with *FAKE-SCRIPT* lists"))

(defun make-fake-session (receiver)
  "A fake session that reports to RECEIVER"
  (make-instance 'fake-session :receiver receiver))

(defun deliver (session event)
  "Send EVENT to SESSION's receiver"
  (funcall (fake-receiver session) event))

(defun open-level (session type report text)
  "Open a debugger level for TYPE and REPORT, raised by TEXT, and
announce it"
  (let ((id (fake-next-id session)))
    (setf (fake-next-id session) (1+ id))
    (push id (fake-open-level-ids session))
    (deliver session (list :level-opened
                           :id id
                           :depth (length (fake-open-level-ids session))
                           :type type
                           :report report
                           :restarts (fake-script-restarts *fake-script*)
                           :backtrace (list (format nil "0: ~A" text)
                                            (format nil "1: (EVAL ~A)" text))))))

(defmethod g:session-eval ((session fake-session) text)
  (let ((reply (assoc text (fake-script-replies *fake-script*) :test #'string=))
        (failure (assoc text (fake-script-errors *fake-script*) :test #'string=)))
    (cond (reply (dolist (event (rest reply)) (deliver session event)))
          (failure (destructuring-bind (type report) (rest failure)
                     (open-level session type report text)))
          (t (deliver session (list :output (format nil ";; The fake session has no script for ~A~%" text)))
             (deliver session (list :values '()))))))

(defmethod g:session-invoke-restart ((session fake-session) id index)
  (let* ((open-level-ids (fake-open-level-ids session))
         (tail (member id open-level-ids)))
    (when tail
      (let ((closing (if (eql index (fake-abort-index *fake-script*))
                         open-level-ids
                         (ldiff open-level-ids (rest tail)))))
        (setf (fake-open-level-ids session) (nthcdr (length closing) open-level-ids))
        (dolist (closed closing)
          (deliver session (list :level-closed closed)))))))

(defmethod g:session-interrupt ((session fake-session))
  (open-level session "TO-RESTART-IS-DIVINE/AGENT:INTERRUPTED" "Interrupted from the page."
              "(interrupt)"))

(defmethod g:session-close ((session fake-session))
  (setf (fake-open-level-ids session) '()))
