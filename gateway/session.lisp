;;;; gateway/session.lisp: what happens between the page and whatever runs the code

(in-package #:to-restart-is-divine/gateway)

;;; A session is made by a constructor of one argument, the receiver,
;;; and reports everything by calling that receiver with one event:
;;;
;;;   (:ready)
;;;   (:output "text")
;;;   (:values ("printed value" ...))
;;;   (:level-opened :id ID :depth N :type "TYPE" :report "text"
;;;           :restarts ((INDEX "NAME" "report") ...) :backtrace ("frame" ...))
;;;   (:level-closed ID)
;;;
;;; The receiver may be called on any thread, including the caller's own
;;; thread from inside SESSION-EVAL. Callers must not hold a lock the receiver
;;; takes while calling into a session.

(defclass session ()
  ()
  (:documentation "One visitor's connection to a Lisp that runs their code"))

(defgeneric session-eval (session text)
  (:documentation "Send TEXT to be read and evaluated. The caller never reads it"))

(defgeneric session-invoke-restart (session id index)
  (:documentation "Answer the debugger level ID by invoking its restart number INDEX"))

(defgeneric session-interrupt (session)
  (:documentation "Interrupt whatever SESSION is evaluating"))

(defgeneric session-close (session)
  (:documentation "End SESSION. No events are sent after this returns"))
