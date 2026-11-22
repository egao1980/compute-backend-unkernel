(in-package #:compute-backend-unkernel/tests)

;;; FORWARD-PORT is the TCP-to-vsock shim: a host 127.0.0.1 port bridged to a guest
;;; port. R4h-4b runs Swank behind it so repl-protocol and lisp-mcp attach unchanged
;;; (+UNKERNEL-PLACEMENT+ :microvm). Here (live): a guest SBCL REPL behind nc, as in
;;; the spike, reached from the host through the forward, with no network.

(deflive forward-guest-lisp-repl (backend)
  (with-session (s backend nil)
    (ok (eq :none (plan-network (unkernel-session-plan s))) "no network: vsock only")
    (sh s (concatenate 'string
                       "nohup sh -c 'nc -l -p 7074 -e sbcl --noinform --no-sysinit --no-userinit"
                       " --disable-debugger' > /dev/null 2>&1 &"))
    (sleep 2)
    (let ((port (forward-port s 7074)))
      (unwind-protect
           (let ((reply (tcp-exchange port (format nil "(format t \"~~&ANSWER ~~a~~%\" (+ 40 2))~%(sb-ext:exit)~%"))))
             (ok (search "ANSWER 42" reply) "a guest Lisp evaluates a form sent from the host"))
        (close-forward s port)))))

(deflive forward-local-port-chosen (backend)
  (with-session (s backend nil)
    (multiple-value-bind (listener free) (open-listener)
      (close-socket listener)
      (let ((port (forward-port s 7075 :local-port free)))
        (ok (eql free port) "an explicit :local-port is used")
        (ok (equal (list free) (unkernel-session-forwards s)))
        (ok (eq t (close-forward s port)))))
    (let ((a (forward-port s 7076))
          (b (forward-port s 7077)))
      (ok (/= a b))
      (ok (equal (sort (list a b) #'<) (unkernel-session-forwards s)) "ascending")
      (ok (eq t (sc:close-sandbox s)))
      (ok (not (tcp-connect-p a)) "close-sandbox closes every forward")
      (ok (not (tcp-connect-p b))))))
