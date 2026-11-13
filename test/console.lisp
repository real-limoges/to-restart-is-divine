;;;; test/console.lisp: history and debugger-stack tests

(in-package #:to-restart-is-divine/tests)

(def-suite console-history :in divine-tests)
(in-suite console-history)

(defun recalled (recall-step history)
  "The line RECALL-STEP shows from HISTORY"
  (nth-value 1 (funcall recall-step history)))

(test previous-shows-pushed-line
  (is (equal "a" (recalled #'g:step-recall-older (g:fold-submitted-line (g:make-history) "a")))))

(test previous-stops-at-oldest
  (let ((at-oldest (g:step-recall-older (g:fold-submitted-line (g:make-history) "a"))))
    (multiple-value-bind (history line) (g:step-recall-older at-oldest)
      (is (null line))
      (is (eq at-oldest history)))))

(test next-past-newest-is-empty
  (let ((recalling (g:step-recall-older (g:fold-submitted-line (g:make-history) "a"))))
    (multiple-value-bind (history line) (g:step-recall-newer recalling)
      (is (equal "" line))
      (is (null (g:history-cursor history))))))

(test blank-and-repeat-not-kept
  (let ((history (reduce #'g:fold-submitted-line '("a" "  " "a") :initial-value (g:make-history))))
    (is (equal '("a") (g:history-entries history)))))

(test push-resets-cursor
  (let* ((recalling (g:step-recall-older (g:fold-submitted-line (g:make-history) "a")))
         (pushed (g:fold-submitted-line recalling "b")))
    (is (equal "b" (recalled #'g:step-recall-older pushed)))))

(def-suite console-debugger :in divine-tests)
(in-suite console-debugger)

(defun level (id)
  "A minimal debug-level with ID"
  (g:make-debug-level :id id :depth id))

(test event-debug-level-reads-fields
  (let ((level (g:event-debug-level
                '(:level-opened :id 7 :depth 2 :type "TYPE-ERROR" :report "bad"
                  :restarts ((0 "ABORT" "Top.")) :backtrace ("0: (CAR 5)") :extra t))))
    (is (= 7 (g:debug-level-id level)))
    (is (= 2 (g:debug-level-depth level)))
    (is (equal "TYPE-ERROR" (g:debug-level-type level)))
    (is (equal "bad" (g:debug-level-report level)))
    (is (equal '((0 "ABORT" "Top.")) (g:debug-level-restarts level)))
    (is (equal '("0: (CAR 5)") (g:debug-level-backtrace level)))))

(test drop-older-drops-newer
  (let ((levels (g:push-level (g:push-level '() (level 1)) (level 2))))
    (is (null (g:drop-level levels 1)))))

(test drop-unknown-changes-nothing
  (let ((levels (g:push-level '() (level 1))))
    (is (eq levels (g:drop-level levels 99)))))

(test restart-label-format
  (is (equal "1: [ABORT] Return to top level."
             (g:restart-label '(1 "ABORT" "Return to top level.")))))

(test no-values-note
  (is (equal '(";; No values") (g:values-lines '()))))
