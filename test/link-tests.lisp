;;;; test/link-tests.lisp: an agent in a child SBCL

(in-package #:to-restart-is-divine/tests)

(def-suite local-agent :in divine-tests)
(in-suite local-agent)

(test local-agent-recovers-from-an-error
  (let ((link (ln:open-local-agent)))
    (unwind-protect
         (let ((agent (ln:link-stream link)))
           (is (equal '(:ready) (next agent)))
           (tell agent '(:eval "(car 5)"))
           (let ((debug (next agent)))
             (tell agent (list :invoke-restart (debug-id debug) (restart-index debug "ABORT")))
             (is (equal (list :debug-done (debug-id debug)) (next agent))))
           (tell agent '(:eval "(+ 1 2)"))
           (is (equal '(:values ("3")) (next agent))))
      (ln:close-link link))
    (is (not (uiop:process-alive-p (ln:link-process link))))))
