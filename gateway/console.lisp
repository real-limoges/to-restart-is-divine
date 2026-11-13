;;;; gateway/console.lisp: REPL line history and debugger stack (as plain values)

(in-package #:to-restart-is-divine/gateway)

;;; REPL line history

(defstruct (history (:constructor %make-history (entries cursor)))
  (entries '() :read-only t)            ; submitted lines, newest first
  (cursor nil :read-only t))            ; index into ENTRIES while recalling

(defun make-history ()
  "Empty history"
  (%make-history '() nil))

(defun blank-line-p (line)
  "True when LINE holds only whitespace"
  (every (lambda (char) (member char '(#\Space #\Tab #\Newline #\Return))) line))

;;; Fold - take one submitted line into the history.
;;; (history line) -> history

(defun fold-submitted-line (history line)
  "HISTORY with LINE added and cursor reset. Blank lines and repeats of the newest entry are not added"
  (let ((entries (history-entries history)))
    (%make-history (if (or (blank-line-p line) (equal line (first entries)))
                       entries
                       (cons line entries))
                   nil)))

;;; Step: the transition for one arrow key while recalling
;;; (history) -> (values history line). LINE is what the REPL line shows now or NIL

(defun step-recall-older (history)
  "Go to the next older entry. The line is NIL at the oldest"
  (let* ((entries (history-entries history))
         (cursor (history-cursor history))
         (older (if cursor (1+ cursor) 0)))
    (if (< older (length entries))
        (values (%make-history entries older) (nth older entries))
        (values history nil))))

(defun step-recall-newer (history)
  "Go to the next newer entry. Past the newest, the line is empty and the cursor clears"
  (let ((entries (history-entries history))
        (cursor (history-cursor history)))
    (cond ((null cursor) (values history nil))
          ((zerop cursor) (values (%make-history entries nil) ""))
          (t (values (%make-history entries (1- cursor)) (nth (1- cursor) entries))))))

;;; Debugger stack

(defstruct debug-level
  id depth type report restarts backtrace)

(defun event-debug-level (event)
  "The debugger level a (:level-opened ...) EVENT describes"
  (destructuring-bind (&key id depth type report restarts backtrace &allow-other-keys)
      (rest event)
    (make-debug-level :id id :depth depth :type type :report report
                      :restarts restarts :backtrace backtrace)))

(defun push-level (levels level)
  "LEVELS with LEVEL opened on top"
  (cons level levels))

;;; Closing a level drops it and every newer one
;;; (levels id) -> levels

(defun drop-level (levels id)
  "LEVELS without level ID and every level newer than it. Unknown IDs change nothing"
  (let ((tail (member id levels :key #'debug-level-id)))
    (if tail
        (rest tail)
        levels)))

(defun restart-label (restart)
  "Button text for RESTART, an (index name report) list"
  (destructuring-bind (index name report) restart
    (format nil "~D: [~A] ~A" index name report)))

(defun values-lines (printed-values)
  "One scrollback line per printed value or a note when there are none"
  (or printed-values (list ";; No values")))
