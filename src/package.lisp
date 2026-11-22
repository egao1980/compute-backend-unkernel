(defpackage #:compute-backend-unkernel
  (:use #:cl)
  (:nicknames #:stack-compute-unkernel)
  (:local-nicknames (#:sc #:compute-protocol)
                    (#:pp #:process-protocol))
  (:export
   ;; pins (src/pins.lisp)
   #:+unkernel-version+
   #:+unkernel-integrity+
   #:+unkernel-tarball+
   #:+alpine-image+
   #:+alpine-sha256+
   #:+guest-packages+
   #:+node-min-major+
   #:+unkernel-features+
   #:+default-memory-mib+
   #:+min-memory-mib+
   #:+max-memory-mib+
   #:+guest-home+
   #:+host-command-port+
   #:+unkernel-placement+

   ;; conditions
   #:unkernel-error
   #:unkernel-error-code
   #:unkernel-error-data
   #:unkernel-session-closed
   #:unkernel-session-closed-session

   ;; host process, HOME layout
   #:default-unkernel-home
   #:host-directory
   #:host-script-pathname
   #:setup-script-pathname
   #:probe-node
   #:host-command
   #:host-check

   ;; backend
   #:unkernel-backend
   #:unkernel-backend-p
   #:make-unkernel-backend
   #:use-unkernel-backend
   #:unkernel-backend-node
   #:unkernel-backend-home
   #:unkernel-backend-memory-mib
   #:unkernel-backend-boot-timeout

   ;; plan (pure)
   #:unkernel-plan
   #:unkernel-plan-p
   #:plan-session
   #:plan-mounts
   #:plan-network
   #:plan-memory-mib
   #:plan-env
   #:plan-directory
   #:plan-tmp
   #:plan-disk
   #:plan-request

   ;; sessions
   #:unkernel-session
   #:unkernel-session-p
   #:unkernel-session-plan
   #:unkernel-session-alive-p
   #:unkernel-session-pid
   #:unkernel-session-boot-ms
   #:unkernel-session-forwards
   #:session-exec
   #:forward-port
   #:close-forward))

(in-package #:compute-backend-unkernel)
