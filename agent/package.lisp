;;;; agent/package.lisp

(defpackage #:to-restart-is-divine/agent
  (:use #:cl #:to-restart-is-divine/wire)
  (:export #:start-agent #:wait-for-agent #:run-agent #:interrupted))
