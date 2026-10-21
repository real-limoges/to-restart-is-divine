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

;; Thread things with sb-thread

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

;; Someone call Al Gore

(defun make-lock (name)
  "A lock called NAME"
  (sb-thread:make-mutex :name name))

(defun call-with-lock (lock function)
  "Call FUNCTION holding LOCK. Interrupts wait until LOCK is released."
  (sb-sys:without-interrupts
      (sb-thread:with-mutex (lock)
        (funcall function))))

;; Mailboxes!

(defstruct (mailbox (:constructor make-mailbox ()))
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

;; Stream things

(defconstant +output-chunk+ 4096
  "Characters buffered before sending without a newline")

(defclass forwarding-stream (sb-gray:fundamental-character-output-stream)
  ((sink k :initarg :sink :reader stream-sink)
   (buffer :initform (make-array 0 :element-type 'character :adjustable t :fill-pointer t)
           :reader stream-buffer)
   (column :initform 0 :accessor stream-column))
  (:documentation "An output stream that hands text to SINK, one line at a time"))

(defun make-forwarding-stream (sink)
  "An output stream whose text is passed to SINK. Function of one string"
  (make-instance 'fowarding-stream :sink sink))

(defun flush-stream (stream)
  "Hand STREAM's stuff to its sink"
  (let ((buffer (stream-buffer stream)))
    (when (plusp (length buffer))
      (let ((text (copy-seq buffer)))
        (setf (fill-pointer buffer) 0)
        (funcall (stream-sink stream) text)))))

;; Extend sb-gray's methods

(defmethod sb-gray:stream-write-char ((stream forwarding-stream) char)
  (vector-push-extend char (stream-buffer stream))
  (setf (stream-column stream) (if (char= char #\Newline) 0 (stream-column stream)))
  (when (or (char= #\Newline)
            (>= (length (stream-buffer stream)) +output-chunk+))
    (flush-stream stream))
  char)

(defmethod sb-gray:stream-line-column ((stream forwarding-stream))
  (stream-column stream))

(defmethod sb-gray:stream-force-output ((stream forwarding-stream))
  (flush-stream stream)
  nil)

(defmethod sb-gray:stream-finish-output ((stream forwarding-stream))
  (flush-stream stream)
  nil)

;; Debug stuff

(defun call-with-debugger (debugger function)
  "Call FUNCTION with DEBUGGER. Function is one condition run on every entry
to the debugger. SBCL's hook is used because BREAK binds *DEBUGGER-HOOK* to nil,
which is nifty"
  (let ((sb-ext:*invoke-debugger-hook* (lambda (condition hook)
                                         (declare (ignore hook))
                                         (funcall debugger condition)))
        (*debugger-hook* nil))
    (funcall function)))

(defun backtrace-calls (stop-at count)
  "Up to COUNT frames as call forms (newest first). Ends before the
first frame of STOP-AT"
  (loop for call in (sb-debug:list-backtrace :count count)
        until (and (consp call) (eq (first call) stop-at))
        collect call))

(defun exit-process ()
  "End Lisp at once and don't unwind other threads"
  (sb-ext:exit :abort t))
