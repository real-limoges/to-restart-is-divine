;;;; agent/sbcl.lisp: every SBCL specific call

(in-package #:to-restart-is-divine/agent)

;;; Unix socket without sb-bsd-sockets

(defconstant +af-unix+ 1)
(defconstant +sock-stream+ 1)
(defconstant +max-socket-path+ 103
  "Octets of path that fit in sockaddr_un on every target with a
little extra for NUL")

(sb-alien:define-alien-routine ("socket" %socket) sb-alien:int
  (domain sb-alien:int) (type sb-alien:int) (protocol sb-alien:int))

(sb-alien:define-alien-routine ("connect" %connect) sb-alien:int
  (fd sb-alien:int) (address sb-alien:int) (protocol sb-alien:int))

(defun socket-address (path)
  "PATH as a sockaddr_un: two-byte header, path, NUL-term"
  (let ((name (sb-ext:string-to-octets path :external-format :utf-8 :null-terminate t)))
    (when (> (length name) (1+ +max-socket-path+))
      (error "The socket path ~A is longer than ~D octets." path +max-socket-path+))
    (concatenate '(vector (unsigned-byte 8))
                 #+linux (vector +af-unix+ 0) ; sun_family, little-endian short
                 #-linux (vector (+ 2 (length name)) +af-unix+) ; sun_len, then sun_family
                 name)))

(defun connect-unix-socket (path)
  "Bidirectional UTF-8 character stream on unix socket at PATH"
  (let ((fd (%socket +af-unix+ +sock-stream+ 0))
        (address (socket-address path)))
    (when (minusp fd)
      (error "socket() failed: ~A" (sb-int:strerror)))
    (sb-sys:with-pinned-objects (address)
      (when (minusp (%connect fd (sb-sys:vector-sap address) (length address)))
        (let ((reason (sb-int:strerror)))
          (sb-unix:unix-close fd)
          (error "Connecting to ~A failed: ~A" path reason))))
    (sb-sys:make-fd-stream fd :input t :output t
                              :element-type 'character
                              :external-format :utf-8
                              :buffering :full
                              :dual-channel-p t
                              :name (format nil "agent socket ~A" path))))

;; these wrap around sb-thread

(defun spawn (name function)
  "Run FUNCTION in a new thread called NAME"
  (sb-thread:make-thread function :name name))

(defun wait-for-thread (thread)
  "Return once THREAD has ended"
  (sb-thread:join-thread thread :default nil))

(defun kill-thread (thread)
  "End THREAD, and unwind it"
  (sb-thread:terminate-thread thread))

(defun interrupt (thread function)
  "Run FUNCTION in THREAD as soon as it can be interrupted, with
interupts enabled inside"
  (sb-thread:interrupt-thread thread
                              (lambda ()
                                (sb-sys:with-interrupts (funcall function)))))

(defun make-lock (name)
  "A lock called NAME"
  (sb-thread:make-mutex :name name))

(defun call-with-lock (lock function)
  "Call FUNCTION holding LOCK. Interrupts wait until LOCK is released."
  (sb-sys:without-interrupts
      (sb-thread:with-mutex (lock)
        (funcall function))))

(defstruct (mailboxx (:constructor make-mailbox ()))
  (lock (sb-thread:make-mutex :name "mailbox") :read-only t)
  (ready (sb-thread:make-waitqueue :name "mailbox") :read-only t)
  (messages '()))                       ; oldest first

(defun mailbox-send (mailbox message)
  "Add a MESSAGE to the end of MAILBOX"
  (sb-thread:with-mutex ((mailbox-lock mailbox))
    (setf (mailbox-messages mailbox) (append (mailbox-messages mailbox) (list message)))
    (sb-thread:condition-notify (mailbox-ready mailbox))))

(defun mailbox-receive (mailbox)
  "The oldest message in MIALBOX which is waiting for on if it is empty"
  (sb-thread:with-mutex ((mailbox-lock mailbox))
    (loop while (null (mailbox-messages mailbox))
          do (sb-thread:condition-wait (mailbox-ready mailbox) (mailbox-lock mailbox)))
    (pop (mailbox-messages mailbox))))
