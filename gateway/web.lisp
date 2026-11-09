;;;; gateway/web.lisp: The CLOG page (the only file that talks to CLOG)

(defpackage #:to-restart-is-divine/web
  (:use #:cl)
  (:local-nicknames (#:g #:to-restart-is-divine/gateway))
  (:export #:start-web #:stop-web))

(in-package #:to-restart-is-divine/web)

(defparameter *page-css*
  (format nil "~{~A~^ ~}"
          '("body { margin: 0; height: 100vh; display: grid; grid-template-columns: 2fr 1fr; font: 16px/1.5 ui-monospace, Menlo, monospace; }"
            ".console { display: flex; flex-direction: column; min-height: 0; padding: 1rem; gap: 0.5rem; }"
            ".scrollback { flex: 1; overflow-y: auto; white-space: pre-wrap; }"
            ".echo { font-weight: bold; }"
            ".debugger:empty { display: none; }"
            ".level { border-left: 4px solid firebrick; padding: 0.5rem; margin-bottom: 0.5rem; }"
            ".condition { white-space: pre-wrap; }"
            ".restart { display: block; margin: 0.25rem 0; text-align: left; font: inherit; }"
            ".frame { color: dimgray; }"
            ".input { font: inherit; padding: 0.25rem; }"
            ".lesson { padding: 1rem; overflow-y: auto; border-left: 1px solid silver; }"))
  "The page's stylesheet, as one line with no quote characters.")

;;; One tab has its elements, its console values, its session and the lock
;;; that serializes its DOM writes

(defstruct (page (:constructor %make-page))
  scrollback panel input-box interrupt-button
  (history (g:make-history))
  (levels '())
  session
  (lock (sb-thread:make-mutex :name "page")))

(defun start-web (&key make-session (port 8417))
  "Serve the console on 127.0.0.1:PORT. MAKE-SESSION takes an event handler
and returns a session"
  (setf clog-connection:*break-on-error* nil)
  (clog:initialize (lambda (body) (on-new-window body make-session))
                   :host "127.0.0.1"
                   :port port))

(defun stop-web ()
  "Stop serving all the tabs"
  (clog:shutdown))

(defun on-new-window (body make-session)
  "Build one tab's page and run it til it is closed. Then close its session"
  (let ((page (build-page body)))
    (setf (page-session page)
          (funcall make-session (lambda (event) (handle-event page event))))
    (attach-page-handlers page)
    (clog:run body)
    (g:session-close (page-session page))))

(defun build-page (body)
  "Lay out the page in BODY and return its struct.
Handlers are attached completely separately"
  (setf (clog:title (clog:html-document body)) "To Restart is Divine")
  (clog:create-style-block body :content *page-css*)
  (let* ((console (clog:create-div body :class "console"))
         (scrollback (clog:create-div console :class "scrollback"))
         (panel (clog:create-div console :class "debugger"))
         (input-box (clog:create-form-element console :text :class "input"))
         (interrupt-button (clog:create-button console :content "Interrupt" :class "interrupt"))
         (lesson (clog:create-div body :class "lesson")))
    (setf (clog:text lesson) "Lesson prose <insert here>")
    (%make-page :scrollback scrollback :panel panel
                :input-box input-box :interrupt-button interrupt-button)))

(defun attach-page-handlers (page)
  "Attach the input and interrupt handlers and focus the input line"
  (clog:set-on-key-down (page-input-box page)
                        (lambda (input data)
                          (declare (ignore input))
                          (on-key page (getf data :key))))
  (clog:set-on-click (page-interrupt-button page)
                     (lambda (button)
                       (declare (ignore button))
                       (interrupt-session page)))
  (sb-thread:with-mutex ((page-lock page))
    (clog:focus (page-input-box page))))

(defun on-key (page key)
  "Enter submits the input line and ArrowUp/ArrowDown walk the history"
  (cond ((equal key "Enter") (submit-line page))
        ((equal key "ArrowUp") (recall page #'g:step-recall-older))
        ((equal key "ArrowDown") (recall page #'g:step-recall-newer))))

(defun submit-line (page)
  "Echo, record and clear the input line. Send it, and the send is outside the lock"
  (let ((line (sb-thread:with-mutex ((page-lock page))
                (let ((line (clog:value (page-input-box page))))
                  (setf (clog:value (page-input-box page)) ""
                        (page-history page) (g:fold-submitted-line (page-history page) line))
                  (append-line page "echo" (format nil "* ~A" line))
                  line))))
    (unless (g:blank-line-p line)
      (g:session-eval (page-session page) line))))

(defun recall (page direction)
  "Show the history entry DIRECTION finds (if it finds one.) DIRECTION is STEP-RECALL-OLDER
or STEP-RECALL-NEWER"
  (sb-thread:with-mutex ((page-lock page))
    (multiple-value-bind (history line) (funcall direction (page-history page))
      (setf (page-history page) history)
      (when line
        (setf (clog:value (page-input-box page)) line)))))

(defun choose-restart (page id index)
  "Invoke restart INDEX of level ID and then return the focus to the input line"
  (g:session-invoke-restart (page-session page) id index)
  (sb-thread:with-mutex ((page-lock page))
    (clog:focus (page-input-box page))))

(defun interrupt-session (page)
  "Interrupt the session and then return the focus to the input line"
  (g:session-interrupt (page-session page))
  (sb-thread:with-mutex ((page-lock page))
    (clog:focus (page-input-box page))))

(defun handle-event (page event)
  "Show one session EVENT. Called on whatever thread the session delivers on"
  (sb-thread:with-mutex ((page-lock page))
    (ecase (first event)
      (:ready
       (append-line page "note" ";; Ready."))
      (:output
       (append-line page "output" (second event)))
      (:values
       (dolist (line (g:values-lines (second event)))
         (append-line page "value" line)))
      (:debug
       (setf (page-levels page) (g:push-level (page-levels page) (g:event-debug-level event)))
       (render-panel page))
      (:debug-done
       (setf (page-levels page) (g:fold-debug-done (page-levels page) (second event)))
       (render-panel page)))))

(defun append-line (page class text)
  "Append TEXT to the scrollback as a one line of CLASS and scroll to it.
The caller holds the page lock"
  (let ((scrollback-line (clog:create-div (page-scrollback page) :class class)))
    (setf (clog:text scrollback-line) text)
    (scroll-to-end (page-scrollback page))))

(defun scroll-to-end (element)
  "Scroll ELEMENT to its bottom without a round trip to the browser"
  (let ((id (clog:script-id element)))
    (clog:js-execute element (format nil "~A.scrollTop=~A.scrollHeight" id id))))

(defun render-panel (page)
  "Rebuild the debugger panel from the level stack (newest first). The caller holds
the page lock"
  (let ((panel (page-panel page)))
    (clog:with-connection-cache (panel)
      (clog:destroy-children panel)
      (loop for level in (page-levels page)
            for newest = t then nil
            do (render-level page panel level newest)))))

(defun render-level (page panel level newest)
  "For one level, its condition, a button per restart, and the backtrace if NEWEST"
  (let ((box (clog:create-div panel :class "level")))
    (setf (clog:text (clog:create-div box :class "condition"))
          (format nil "Debugger level ~D: ~A~%~A"
                  (g:debug-level-depth level)
                  (g:debug-level-type level)
                  (g:debug-level-report level)))
    (dolist (restart (g:debug-level-restarts level))
      (let ((button (clog:create-button box :class "restart"))
            (index (first restart)))
        (setf (clog:text button) (g:restart-label restart))
        (clog:set-on-click button
                           (lambda (button)
                             (declare (ignore button))
                             (choose-restart page (g:debug-level-id level) index)))))
    (when newest
      (dolist (frame (g:debug-level-backtrace level))
        (setf (clog:text (clog:create-div box :class "frame")) frame)))))
