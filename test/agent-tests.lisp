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
