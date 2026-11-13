;;;; test/agent-tests.lisp: the in-process agent driven over a real socket

(in-package #:to-restart-is-divine/tests)

(def-suite agent :in divine-tests)
(in-suite agent)

(defun next (stream)
  "Next message on STREAM, or NIL + failed check after five seconds"
  (handler-case (sb-sys:with-deadline (:seconds 5)
                  (w:read-message stream))
    (sb-sys:deadline-timeout ()
      (fail "No message within five seconds.")
      nil)))

(defun next-past-output (stream)
  "The next message on STREAM, but not :output"
  (loop for message = (next stream)
        while (eq :output (first message))
        finally (return message)))

(defun send-to-agent (stream message)
  "Send MESSAGE to the agent on STREAM"
  (w:write-message message stream))

(defun level-id-of (opened)
  "Level id of OPENED, a :level-opened message"
  (getf (rest opened) :id))

(defun restart-index (opened name)
  "Index of first restart in OPENED called NAME"
  (first (find name (getf (rest opened) :restarts) :key #'second :test #'string=)))

(defun call-with-agent (function)
  "Call FUNCTION with gateway's end of an in-process agent, once it says :ready.
After, hang up and wait for the agent's threads to end"
  (let* ((directory (ln:create-socket-directory))
         (path (ln:socket-path directory))
         (listener (ln:make-agent-listener path))
         (agent (a:start-agent path))
         (stream (ln:accept-agent-stream listener :timeout 5)))
    (sb-bsd-sockets:socket-close listener)
    (delete-file path)
    (uiop:delete-empty-directory directory)
    (unwind-protect
         (progn
           (is (equal '(:ready) (next stream)))
           (funcall function stream))
      (close stream :abort t)
      (a:wait-for-agent agent))))

(test ping-answers-pong
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:ping))
     (is (equal '(:pong) (next stream))))))

(test eval-sends-printed-values
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(+ 1 2)"))
     (is (equal '(:values ("3")) (next stream)))
     (send-to-agent stream '(:eval "(values)"))
     (is (equal '(:values ()) (next stream))))))

(test output-precedes-values
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(princ \"hi\")"))
     (is (equal '(:output "hi") (next stream)))
     (is (equal '(:values ("\"hi\"")) (next stream))))))

(test forms-evaluate-in-turn
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(+ 1 2) (* * 2)"))
     (is (equal '(:values ("3")) (next stream)))
     (is (equal '(:values ("6")) (next stream))))))

(test error-opens-level-one
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(car 5)"))
     (destructuring-bind (kind &key depth type restarts backtrace &allow-other-keys) (next stream)
       (is (eq :level-opened kind))
       (is (= 1 depth))
       (is (equal "TYPE-ERROR" type))
       (is (equal '(("RETRY" "Evaluate the form again.") ("ABORT" "Return to top level."))
                  (mapcar #'rest (last restarts 2))))
       (is (search "CAR" (first backtrace)))))))

(test abort-returns-to-top-level
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(car 5)"))
     (let ((opened (next stream)))
       (send-to-agent stream (list :invoke-restart (level-id-of opened) (restart-index opened "ABORT")))
       (is (equal (list :level-closed (level-id-of opened)) (next stream))))
     (send-to-agent stream '(:eval "(+ 1 2)"))
     (is (equal '(:values ("3")) (next stream))))))

(test abort-closes-every-level
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(car 5)"))
     (let ((outer (next stream)))
       (send-to-agent stream '(:eval "(/ 1 0)"))
       (let ((inner (next stream)))
         (is (= 2 (getf (rest inner) :depth)))
         (send-to-agent stream (list :invoke-restart (level-id-of inner) (restart-index inner "ABORT")))
         (is (equal (list :level-closed (level-id-of inner)) (next stream)))
         (is (equal (list :level-closed (level-id-of outer)) (next stream))))))))

(test inner-restart-closes-its-own-level
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(car 5)"))
     (let ((outer (next stream)))
       (send-to-agent stream '(:eval "(restart-case (error \"x\") (retreat () :report \"Back off.\" 42))"))
       (let ((inner (next stream)))
         (send-to-agent stream (list :invoke-restart (level-id-of inner) (restart-index inner "RETREAT")))
         (is (equal (list :level-closed (level-id-of inner)) (next stream)))
         (is (equal '(:values ("42")) (next stream)))
         (send-to-agent stream (list :invoke-restart (level-id-of outer) (restart-index outer "ABORT")))
         (is (equal (list :level-closed (level-id-of outer)) (next stream))))))))

(test break-enters-the-agent-debugger
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(break)"))
     (let ((opened (next stream)))
       (is (eq :level-opened (first opened)))
       (send-to-agent stream (list :invoke-restart (level-id-of opened) (restart-index opened "CONTINUE")))
       (is (equal (list :level-closed (level-id-of opened)) (next stream)))
       (is (equal '(:values ("NIL")) (next stream)))))))

(test interrupt-opens-a-level-over-a-running-loop
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(progn (princ \"go\") (finish-output) (loop))"))
     (is (equal '(:output "go") (next stream)))
     (send-to-agent stream '(:interrupt))
     (let ((opened (next stream)))
       (is (equal "TO-RESTART-IS-DIVINE/AGENT:INTERRUPTED" (getf (rest opened) :type)))
       (is (equal "CONTINUE" (second (first (getf (rest opened) :restarts)))))
       (send-to-agent stream (list :invoke-restart (level-id-of opened) (restart-index opened "ABORT")))
       (is (equal (list :level-closed (level-id-of opened)) (next stream)))))))

(test unreadable-text-opens-a-level
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "("))
     (let ((opened (next stream)))
       (is (eq :level-opened (first opened)))
       (send-to-agent stream (list :invoke-restart (level-id-of opened) (restart-index opened "ABORT")))
       (is (equal (list :level-closed (level-id-of opened)) (next stream)))))))

(test output-is-sent-before-the-debugger-opens
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(progn (princ \"a\") (car 5))"))
     (is (equal '(:output "a") (next stream)))
     (is (eq :level-opened (first (next stream)))))))

(test retry-after-redefining
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(defun f (x) (car x))"))
     (is (equal '(:values ("F")) (next stream)))
     (send-to-agent stream '(:eval "(f 5)"))
     (let ((opened (next stream)))
       (send-to-agent stream '(:eval "(defun f (x) (if (listp x) (car x) x))"))
       (is (equal '(:values ("F")) (next-past-output stream)))
       (send-to-agent stream (list :invoke-restart (level-id-of opened) (restart-index opened "RETRY")))
       (is (equal (list :level-closed (level-id-of opened)) (next stream)))
       (is (equal '(:values ("5")) (next stream)))))))

(test circular-value-prints-with-labels
  (call-with-agent
   (lambda (stream)
     (send-to-agent stream '(:eval "(let ((x (list 1 2 3))) (setf (cdr (last x)) x))"))
     (is (equal '(:values ("#1=(1 2 3 . #1#)")) (next stream))))))
