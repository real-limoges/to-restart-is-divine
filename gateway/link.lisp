;;;; gateway/link.lisp: the gateway's end of the agent socket

(defpackage #:to-restart-is-divine/link
  (:use #:cl)
  (:export #:create-socket-directory #:socket-path #:make-agent-listener #:accept-agent-stream
           #:link #:link-stream #:link-process #:open-agent-process #:close-link))

(in-package #:to-restart-is-divine/link)

(defun create-socket-directory ()
  "New empty directory for one agent socket"
  (let ((directory (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "divine-~36R" (random (expt 2 64) (make-random-state t)))
                                     (uiop:temporary-directory)))))
    (unless (nth-value 1 (ensure-directories-exist directory))
      (error "The socket directory ~A already exists." directory))
    directory))

(defun socket-path (directory)
  "Agent socket's path inside DIRECTORY as native namestring"
  (uiop:native-namestring (merge-pathnames "agent.sock" directory)))

(defun make-agent-listener (path)
  "A socket listening at PATH for an agent"
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-bind socket path)
    (sb-bsd-sockets:socket-listen socket 1)
    socket))

(defun accept-agent-stream (listener &key (timeout 30))
  "Stream of the first agent to connect to LISTENER, waiting no more than
TIMEOUT seconds"
  (unless (sb-sys:wait-until-fd-usable (sb-bsd-sockets:socket-file-descriptor listener) :input timeout)
    (error "No agent connected within ~D seconds." timeout))
  (sb-bsd-sockets:socket-make-stream (sb-bsd-sockets:socket-accept listener)
                                     :input t :output t
                                     :element-type 'character
                                     :external-format :utf-8
                                     :buffering :full))

;;; A link is the gateway's stream to one agent plus the agent's SBCL process,
;;; which loads the agent from source
(defstruct (link (:constructor %make-link (stream process)))
  (stream nil :read-only t)
  (process nil :read-only t))

(defun agent-command (path)
  "Command line of the agent's SBCL process, which loads the agent + answers the gateway at PATH"
  (list "sbcl" "--noinform" "--no-sysinit" "--no-userinit" "--disable-debugger"
        "--eval" "(require :asdf)"
        "--eval" (format nil "(asdf:load-asd ~S)"
                         (uiop:native-namestring (asdf:system-source-file "to-restart-is-divine")))
        "--eval" "(asdf:load-system \"to-restart-is-divine/agent\")"
        "--eval" (format nil "(to-restart-is-divine/agent:run-agent ~S)" path)))

(defun open-agent-process (&key (timeout 30))
  "Start agent in its own SBCL process and return its link once it's connected.
Socket + directory are deleted as soon as the agent has arrived or fails to arrive"
  (let* ((directory (create-socket-directory))
         (path (socket-path directory))
         (listener (make-agent-listener path))
         (process (uiop:launch-program (agent-command path)
                                       :input nil
                                       :output :interactive
                                       :error-output :interactive))
         (link nil))
    (unwind-protect
         (setf link (%make-link (accept-agent-stream listener :timeout timeout) process))
      (sb-bsd-sockets:socket-close listener)
      (delete-file path)
      (uiop:delete-empty-directory directory)
      (unless link
        (uiop:terminate-process process :urgent t)))
    link))

(defun close-link (link)
  "Kill agent's process, wait for it, and then close the stream"
  (uiop:terminate-process (link-process link) :urgent t)
  (uiop:wait-process (link-process link))
  (close (link-stream link) :abort t))
