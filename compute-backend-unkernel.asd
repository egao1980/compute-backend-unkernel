(defsystem "compute-backend-unkernel"
  :version "0.1.0"
  :description "Fallback sandbox backend for compute-protocol: sessions in unkernel (Linux compiled to WebAssembly, run under Node), no hypervisor or root"
  :author "egao1980"
  :license "MIT"
  ;; No foreign library. The kernel runs in a Node host process (host/, an
  ;; asset with exactly pinned npm deps) spawned through process-protocol and
  ;; driven over newline JSON-RPC (rpc-backend-stdio). Node 24+ is a runtime
  ;; dependency, probed; missing → CONFINEMENT-UNAVAILABLE.
  :depends-on ((:version "compute-protocol" "0.3.2")
               (:version "process-protocol" "0.4.1")
               (:version "process-backend-uiop" "0.3.4")
               (:version "rpc-protocol" "0.2.0")
               (:version "rpc-protocol-json" "0.1.1")
               (:version "rpc-backend-stdio" "0.3.2")
               (:version "json-protocol" "0.2.3")
               "json-backend-jzon"
               "bordeaux-threads"
               "uiop")
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "conditions")
                             (:file "pins")      ; pinned unkernel / distro / guest versions
                             (:file "backend")   ; UNKERNEL-BACKEND: class, features, availability
                             (:file "host")      ; Node probe, HOME layout, host argv, HOST-CHECK
                             (:file "plan")      ; spec → session plan (pure), the open request
                             (:file "session"))) ; open / exec / run / close, forwards, timeouts
               ;; The Node host, an asset: unkernel pinned exactly (package.json + lockfile).
               (:module "host"
                :components ((:static-file "unkernel-host.mjs")
                             (:static-file "package.json")
                             (:static-file "package-lock.json")))
               ;; npm ci of the host, the pinned distro and the guest disk into HOME.
               (:module "scripts"
                :components ((:static-file "setup.sh"))))
  :in-order-to ((test-op (test-op "compute-backend-unkernel/tests"))))

(defsystem "compute-backend-unkernel/suite"
  :version "0.1.0"
  :description "compute-protocol's confinement suite through an unkernel session (the probe runs on the guest's SBCL)"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "compute-backend-unkernel" "0.1.0")
               (:version "compute-protocol/confinement-suite" "0.3.2"))
  :serial t
  :pathname "src/suite"
  :components ((:file "suite"))
  :in-order-to ((test-op (test-op "compute-backend-unkernel/tests"))))

(defsystem "compute-backend-unkernel/tests"
  :depends-on ("compute-backend-unkernel"
               (:feature :sbcl "compute-backend-unkernel/suite")
               (:feature :sbcl "sb-bsd-sockets")
               "json-protocol"
               "json-backend-jzon"
               "rove"
               "uiop")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "pin-test")            ; every OS: the pins; live: host.check, guest versions
               (:file "plan-test")           ; Unix, pure: spec → plan, refusals, the open request
               (:file "availability-test")   ; every OS: fail closed without Node / setup
               (:file "session-test")        ; live: open / exec / close, exit codes, stdout / stderr
               (:file "area-test")           ; live: the read-write area round trip, private TMPDIR
               (:file "timeout-test")        ; live: a wall-clock kills the session
               (:file "close-test")          ; live: close releases everything
               (:file "forward-test")        ; live: the TCP-to-vsock shim, a guest Lisp behind it
               (:file "isolation-test")      ; live: the extra laws from the spike
               (:file "suite-test" :if-feature :sbcl))  ; live: compute-protocol's suite, 18 laws
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
