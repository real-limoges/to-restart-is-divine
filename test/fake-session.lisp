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
