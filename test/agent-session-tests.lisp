;;;; test/agent-session-tests.lisp: A real agent to test against

(in-package #:to-restart-is-divine/tests)

(def-suite agent-session :in divine-tests)
(in-suite agent-session)

(defun waiting-recorder ()
  "An event handler and a function returning the next event it was given.
It waits up to 10 seconds"
  (let ((lock (sb-thread:make-mutex :name "recorder"))
        (arrived (sb-thread:make-waitqueue :name "recorder"))
        (events '()))
    (values (lambda (event)
              (sb-thread:with-mutex (lock)
                (setf events (append events (list event)))
                (sb-thread:condition-broadcast arrived)))
            (lambda ()
              (sb-thread:with-mutex (lock)
                (loop repeat 10
                      while (null events)
                      do (sb-thread:condition-wait arrived lock :timeout 1))
                (pop events))))))

(test agent-session-recovers-from-an-error
  (multiple-value-bind (handler next-event) (waiting-recorder)
    (let ((session (g:make-local-agent-session handler)))
      (unwind-protect
           (progn
             (is (equal '(:ready) (funcall next-event)))
             (g:session-eval session "(car 5)")
             (let ((level (g:event-debug-level (funcall next-event))))
               (g:session-invoke-restart session
                                         (g:debug-level-id level)
                                         (first (find "ABORT" (g:debug-level-restarts level)
                                                      :key #'second :test #'string=)))
               (is (equal (list :debug-done (g:debug-level-id level)) (funcall next-event)))))
        (g:session-close session)))))

(test closed-session-ignores-calls
  (let ((session (g:make-local-agent-session (lambda (event) (declare (ignore event))))))
    (g:session-close session)
    (finishes (g:session-eval session "(+ 1 2)"))
    (finishes (g:session-interrupt session))))
