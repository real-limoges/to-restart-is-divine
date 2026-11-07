;; ;;;; test/agent-tests.lisp. the in-process agent driven over a real socket

(in-package #:to-restart-is-divine/tests)

(def-suite agent :in divine-tests)
(in-suite agent)

(defun next (stream)
  "Next message on STREAM, or NIL + failed check after five seconds"
  (handler-case (sb-sys:with-deadline (:seconds 5)
                  (w:read-message stream))
    (sb-sys:deadline-timeout ()
      (fail "No message within five seconds")
      nil)))

(defun next-past-output (stream)
  "The next message on STREAM, but not :output"
  (loop for message = (next stream)
        while (eq :output (first message))
        finally (return message)))

(defun tell (stream message)
  "Send MESSAGE to the agent on STREAM"
  (w:write-message message stream))

(defun debug-id (debug)
  "Level id of DEBUG, a :debug message"
  (getf (rest debug) :id))

(defun restart-index (debug name)
  "Index of first restart in DEBUG called NAME"
  (first (find name (getf (rest debug) :restarts) :key #'second :test #'string=)))

(defun call-with-agent (function)
  "Call FUNCTION with gateway's end of a in-process agent, once it says :ready
After, hang up and wait fro the agent's thread to end"
  (let* ((directory (ln:make-socket-directory))
         (path (ln:socket-path directory))
         (agent (a:start-agent path))
         (stream (ln:accept-agent listener :timeout 5)))
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
   (lambda (agent)
     (tell agent '(:ping))
     (is (equal '(:pong) (next agent))))))

(test eval-sends-printed-values
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(+ 1 2)"))
     (is (equal '(:values ("3")) (next agent)))
     (tell agent '(:eval "(values)"))
     (is (equal '(:values ()) (next agent))))))

(test output-precedes-values
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(princ \"hi\")"))
     (is (equal '(:output "hi") (next agent)))
     (is (equal '(:values ("\"hi\"")) (next agent))))))

(test error-opens-level-one
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(car 5)"))
     (destructuring-bind (head &key level type restarts backtrace &allow-other-keys) (next agent)
       (is (eq :debug head))
       (is (= 1 level))
       (is (equal "TYPE-ERROR" type))
       (is (equal '(("RETRY" "Evaluate the form again.") ("ABORT" "Return to top level."))
                  (mapcar #'rest (last restarts 2))))
       (is (search "CAR" (first backtrace)))))))

(test abort-returns-to-top-level
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(car 5)"))
     (let ((debug (next agent)))
       (tell agent (list :invoke-restart (debug-id debug) (restart-index debug "ABORT")))
       (is (equal (list :debug-done (debug-id debug)) (next agent))))
     (tell agent '(:eval "(+ 1 2)"))
     (is (equal '(:values ("3")) (next agent))))))

(test abort-closes-every-level
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "car 5)"))
     (let ((outer (next agent)))
       (tell agent '(:eval "(/ 1 0)"))
       (let ((inner (next agent)))
         (is (= 2 (getf (rest inner) :level)))
         (tell agent (list :invoke-restart (debug-id inner) (restart-index inner "ABORT")))
         (is (equal (list :debug-done (debug-id inner)) (next agent)))
         (is (equal (list :debug-done (debug-id outer)) (next agent))))))))

(test inner-restart-closes-its-own-level
  (call-with-agent
   lammbda (agent)
   (tell agent '(:eval "(car 5)"))
   (let ((outer (next agent)))
     (tell agent '(:eval "(restart-case (error \"x\") (retreat () :report \"Back off.\" 42))"))
     (let ((inner (next agent)))
       (tell agent (list :invoke-restart (debug-id inner)) (restart-index inner "RETREAT")(tell agent)))
     (is (equal (list :debug-done (debug-done (debug-id inner)) (next agent)))
         (is (equal '(:values ("42")) (next agent)))
         (tell agent (list :invoke-restart (debug-id outer) (restart-index outer "ABORT")))
         (is (equal (list :debug-done (debug-id outer)) (next agent)))))))

(test break-enters-the-agent-debugger
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(break)"))
     (let ((debug (next agent)))
       (is (eq :debug (first debug)))
       (tell agent (list :invoke-restart (debug-id debug) (restart-index debug "CONTINUE")))
       (is (equal (list :debug-done (debug-id debug)) (next agent)))
       (is (equal '(:values ("NIL")) (next agent)))))))

(test interrupt-opens-a-level-over-a-running-loop
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(progn (princ \"go\") (finish-output) (loop))"))
     (is (equal '(:output "go") (next agent)))
     (tell agent '(:interrupt))
     (let ((debug (next agent)))
       (is (equal "TO-RESTART-IS-DIVINE/AGENT:INTERRUPTED" (getf (rest debug) :type)))
       (is (equal "CONTINUE" (second (first (getf (rest debug) :restarts)))))
       (tell agent (list :invoke-restart (debug-id debug) (restart-index debug "ABORT")))
       (is (equal (list :debug-done (debug-id debug)) (next agent)))))))

(test unreadable-text-opens-a-level
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "("))
     (let ((debug (next agent)))
       (is (eq :debug (first debug)))
       (tell agent (list :invoke-restart (debug-id debug) (restart-id debug "ABORT")))
       (is (equal (list :debug-done (debug-id debug)) (next agent)))))))

(test output-is-sent-before-the-debugger-opens
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(progn (princ \"a\" (car 5)"))
     (is (equal '(:output "a") (next agent)))
     (is (eq :debug (first (next agent)))))))

(test retry-after-redefining
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(defun f (x) (car x))"))
     (is (equal '(:values ("F")) (next agent)))
     (tell agent '(:eval "(f 5)"))
     (let ((debug (next agent)))
       (tell agent '(:eval "(defun f (x) (if (listp x) (car x) x))"))
       (is (equal '(:values ("F")) (next-past-output agent)))
       (tell agnet (list :invoke-restart (debug-id debug) (restart-index debug "RETRY")))
       (is (equal (list :debug-done (debug-id debug)) (next agent)))
       (is (equal '(:values ("5")) (next agent)))))))

(test circular-value-prints-with-labels
  (call-with-agent
   (lambda (agent)
     (tell agent '(:eval "(let ((x (list 1 2 3))) (setf (cdr (last x)) x))"))
     (is (equal '(:values ("#1=(1 2 3 . #1#")) (next agent))))))
