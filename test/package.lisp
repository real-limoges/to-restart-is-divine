;;;; test/package.lisp
;;;;
;;;; Run with (asdf:test-system "to-restart-is-divine/tests").

(defpackage #:to-restart-is-divine/tests
  (:use #:cl #:fiveam)
  (:local-nicknames (#:w #:to-restart-is-divine/wire)
                    (#:a #:to-restart-is-divine/agent)
                    (#:ln #:to-restart-is-divine/link))
  (:export #:divine-tests))

(in-package #:to-restart-is-divine/tests)

(def-suite divine-tests :description "Everything that runs without CLOG.")
