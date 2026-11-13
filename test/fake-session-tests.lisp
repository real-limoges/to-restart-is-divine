;;;; test/fake-session-tests.lisp: the fake session keeps the session protocol

(in-package #:to-restart-is-divine/tests)

(defvar *never-set*)

(def-suite fake-session :in divine-tests)
(in-suite fake-session)

(defun fake-with-captured-events ()
  "A fake session and a function returning the events it has sent (oldest first)"
  (let* ((events '())
         (session (make-fake-session (lambda (event) (push event events)))))
    (values session (lambda () (reverse events)))))

(test fake-error-opens-level-one
  (multiple-value-bind (session events) (fake-with-captured-events)
    (g:session-eval session "(car 5)")
    (let ((level (g:event-debug-level (first (funcall events)))))
      (is (= 1 (length (funcall events))))
      (is (= 1 (g:debug-level-depth level)))
      (is (plusp (length (g:debug-level-restarts level)))))))

(test fake-abort-closes-every-level
  (multiple-value-bind (session events) (fake-with-captured-events)
    (g:session-eval session "(car 5)")
    (g:session-eval session "(/ 1 0)")
    (g:session-invoke-restart session 2 (fake-abort-index *fake-script*))
    (is (equal '((:level-closed 2) (:level-closed 1)) (subseq (funcall events) 2)))))

(test retry-closes-own-level
  (multiple-value-bind (session events) (fake-with-captured-events)
    (g:session-eval session "(car 5)")
    (g:session-eval session "(/ 1 0)")
    (g:session-invoke-restart session 2 0)
    (is (equal '((:level-closed 2)) (subseq (funcall events) 2)))))

(test unscripted-text-is-not-evaluated
  (multiple-value-bind (session events) (fake-with-captured-events)
    (g:session-eval session "#.(setf *never-set* t)")
    (is (eq :output (first (first (funcall events)))))
    (is (equal '(:values ()) (second (funcall events))))
    (is (not (boundp '*never-set*)))))
