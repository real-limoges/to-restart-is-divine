;;;; test/link-tests.lisp: an agent in its own SBCL process

(in-package #:to-restart-is-divine/tests)

(def-suite link :in divine-tests)
(in-suite link)

(test agent-process-recovers-from-an-error
  (let ((link (ln:open-agent-process)))
    (unwind-protect
         (let ((stream (ln:link-stream link)))
           (is (equal '(:ready) (next stream)))
           (send-to-agent stream '(:eval "(car 5)"))
           (let ((opened (next stream)))
             (send-to-agent stream (list :invoke-restart (level-id-of opened) (restart-index opened "ABORT")))
             (is (equal (list :level-closed (level-id-of opened)) (next stream))))
           (send-to-agent stream '(:eval "(+ 1 2)"))
           (is (equal '(:values ("3")) (next stream))))
      (ln:close-link link))
    (is (not (uiop:process-alive-p (ln:link-process link))))))
