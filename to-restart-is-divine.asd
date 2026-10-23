;;;; to-restart-is-divine.asd

(defsystem "to-restart-is-divine"
  :description "In-Browser Common Lisp REPL with a Showcased Debugger")

(defsystem "to-restart-is-divine/wire"
  :description "Message Framing Shared by Agent and Gateway. ANSI CL Only"
  :components ((:module "agent"
                :components ((:file "wire")))))

(defsystem "to-restart-is-divine/agent"
  :description "Debug Agent Loaded Into Every Lesson. No Deps, No Contribs"
  :depends-on ("to-restart-is-divine/wire")
  :serial t
  :components ((:module "agent"
                :components ((:file "package")
                             (:file "sbcl")
                             (:file "agent")))))

(defsystem "to-restart-is-divine/link"
  :description "The Gateway's End of the Agent Socket + Local Agent in Child SBCL"
  :depends-on ((:require "sb-bsd-sockets"))
  :components ((:module "gateway"
                :components ((:file "link")))))

(defsystem "to-restart-is-divine/tests"
  :description "Every Test Lives Here. No CLOG"
  :depends-on ("to-restart-is-divine/agent"
               "to-restart-is-divine/link"
               "fiveam")
  :serial t
  :components ((:module "test"
                :components ((:file "package")
                             (:file "wire-tests")
                             (:file "agent-tests")
                             (:file "link-tests"))))
  :perform (test-op (o c)
                    (declare (ignore o c))
                    (unless (uiop:symbol-call :fiveam :run!
                                              (uiop:find-symbol* :divine-tests
                                                                 :to-restart-is-divine/tests))
                      (error "to-restart-is-divine tests failed!"))))
