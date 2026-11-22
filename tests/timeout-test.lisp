(in-package #:compute-backend-unkernel/tests)

;;; A wall-clock kills the whole session (live): the host process, the kernel, the
;;; forwards, the private temp dir. SANDBOX-TIMEOUT with ABORT-EXECUTION.

(defun timed-out (thunk)
  "→ (values condition seconds) when THUNK signals SANDBOX-TIMEOUT, else (values NIL seconds)."
  (let ((start (get-internal-real-time)))
    (flet ((elapsed () (/ (- (get-internal-real-time) start) internal-time-units-per-second)))
      (handler-case (progn (funcall thunk) (values nil (elapsed)))
        (sc:sandbox-timeout (c) (values c (elapsed)))))))

(deflive timeout-kills-the-session (backend)
  (with-tree (root area ro outside)
    (let* ((s (sc:open-sandbox backend (area-spec area)))
           (pid (unkernel-session-pid s))
           (tmp (plan-tmp (unkernel-session-plan s))))
      (unwind-protect
           (multiple-value-bind (c seconds) (timed-out (lambda () (sh s "sleep 60" :wall-clock 2)))
             (ok c "SANDBOX-TIMEOUT")
             (ok (and c (eql 2 (sc:sandbox-timeout-limit c))) "its limit is the wall-clock")
             (ok (< seconds 12) (format nil "signalled in ~,1f s (wall-clock 2 + grace)" seconds))
             (ok (not (unkernel-session-alive-p s)) "the session is dead")
             (ok (wait-until (lambda () (not (pid-alive-p pid))) 5) "the host process is gone")
             (ok (not (uiop:directory-exists-p tmp)) "the private temp dir is deleted")
             (ok (signals (sh s "true") 'unkernel-session-closed) "later calls refuse")
             (ok (signals (sc:run-sandboxed s '("true")) 'unkernel-session-closed))
             (ok (null (sc:close-sandbox s)) "close after a kill → NIL"))
        (sc:close-sandbox s)))))

(deflive timeout-abort-execution (backend)
  (with-session (s backend nil)
    (let ((result :unset))
      (handler-bind ((sc:sandbox-timeout
                       (lambda (c)
                         (let ((r (find-restart 'sc:abort-execution c)))
                           (ok r "restart ABORT-EXECUTION")
                           (when r (invoke-restart r))))))
        (setf result (sh s "sleep 60" :wall-clock 1)))
      (ok (null result) "ABORT-EXECUTION → NIL")
      (ok (not (unkernel-session-alive-p s))))))

(deflive timeout-run-sandboxed (backend)
  (let ((before (stack-compute-dirs)))
    (multiple-value-bind (c seconds)
        (timed-out (lambda ()
                     (sc:run-sandboxed backend (sc:make-sandbox-spec :command '("sleep" "60")
                                                                     :wall-clock 2))))
      (ok c "the spec's :wall-clock")
      (ok (< seconds 20) "boot + wall-clock + grace"))
    (ok (equal before (stack-compute-dirs)) "the one-shot session left nothing")))

(deflive timeout-kills-guest-children (backend)
  (with-tree (root area ro outside)
    (let ((s (sc:open-sandbox backend (area-spec area))))
      (unwind-protect
           (progn
             (timed-out (lambda ()
                          (sh s "(while true; do date >> beat.txt; sleep 1; done) & sleep 60"
                              :wall-clock 3)))
             (let ((size (length (or (read-text (merge-pathnames "beat.txt" area)) ""))))
               (sleep 3)
               (ok (= size (length (or (read-text (merge-pathnames "beat.txt" area)) "")))
                   "a background loop in the guest died with the session")))
        (sc:close-sandbox s)))))

(deflive timeout-not-reached (backend)
  (with-session (s backend nil)
    (ok (eql 0 (sh s "sleep 1" :wall-clock 30)))
    (ok (unkernel-session-alive-p s) "a wall-clock that does not pass changes nothing")))
