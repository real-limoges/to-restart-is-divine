;;;; gateway/session.lisp what happens between the page and whatever runs the code

(in-package #:to-restart-is-divine/gateway)

(defclass session ()
  ()
  (:documentation "One visitor's connection to a Lisp that runs their code"))

(defgeneric session-eval (session text)
  (:documentation "Send TEXT to be read/eval. The caller never read it"))

(defgeneric session-invoke-restart (session id index)
  (:documentation "Answer the debugger level ID by invoking its restart number INDEX"))

(defgeneric session-interrupt (session)
  (:documentation "Interrupt whatever SESSION is evaluating"))

(defgeneric session-close (session)
  (:documentation "End SESSION. No events are sent after this returns"))
