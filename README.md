# compute-backend-unkernel

Fallback sandbox backend for [compute-protocol](https://github.com/egao1980/compute-protocol): sessions in [unkernel](https://www.npmjs.com/package/unkernel) (Linux compiled to WebAssembly, run under Node). Portable, no hypervisor or root, for untrusted code where Seatbelt / Landlock or MXC are not available. **Not the default**: compute is 26–34x slower than native.

**Status:** 0.1.0 contract (R4h-4a, [compute-protocol#9](https://github.com/egao1980/compute-protocol/issues/9)). Brief: [cl-stack/docs/capabilities/confinement.md § R4h-4](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/confinement.md).

```lisp
(asdf:load-system "compute-backend-unkernel")

(let ((backend (compute-backend-unkernel:make-unkernel-backend)))
  (compute-protocol:with-sandbox
      (s backend (compute-protocol:make-sandbox-spec
                  :confinement (compute-protocol:make-confinement
                                :writable (list #p"/path/to/area/") :read :system)))
    (compute-backend-unkernel:session-exec s '("sh" "-c" "ls; uname -m"))))
```

## Runtime requirements

- **Node 24+** (`node` on `PATH`, or `COMPUTE_UNKERNEL_NODE`, or `:node`). Missing → `confinement-unavailable`; never an unsandboxed run.
- **`sh scripts/setup.sh [HOME]`** once: installs the pinned host modules (`npm ci --ignore-scripts` of `host/`), the pinned Alpine image and the guest disk. HOME defaults to `$XDG_CACHE_HOME/compute-backend-unkernel/<unkernel version>/`. The backend never downloads anything itself.
- Not Windows hosts (0.1.0).

unkernel `0.2.0-261121-e69adda` is pinned exactly, an exception to the two-week pin rule ([#1](https://github.com/egao1980/compute-backend-unkernel/issues/1)).

## Shape

- compute-protocol GFs: `open-sandbox`, `run-sandboxed` (backend and session), `close-sandbox`, `confinement-features`, `confinement-available-p`, `backend-confine-argv` (refused: a session backend), and the suite's `confinement-probe` (system `compute-backend-unkernel/suite`).
- One Node host process per session (one kernel each), driven over newline JSON-RPC (rpc-backend-stdio).
- Mounts at their own host paths: the confinement's `:writable` trees and the private temp dir read-write, everything else read-only (enforced host-side). No network unless the spec allows it; host functions off; vsock (`forward-port`, a 127.0.0.1 TCP shim) is the only inbound path. Placement `:microvm`.
- Failures are compute-protocol conditions (`confinement-unavailable`, `invalid-confinement`, `sandbox-denied`, `sandbox-timeout` with restart `abort-execution`) plus `unkernel-error` and `unkernel-session-closed`.
- Later (R4h-4b, 0.2.0): the guest boots a prebuilt SBCL session core on a read-only erofs disk, and Swank runs behind `forward-port`.

## Tests

`cl-repo test --system compute-backend-unkernel`. Pin, availability and planning tests run everywhere (planning skips on Windows). Live tests boot a kernel and skip with the reason when Node 24+ or `scripts/setup.sh` is missing, and always on Windows. The CI `unkernel` job (macOS and Ubuntu) sets up Node and HOME and runs with `COMPUTE_UNKERNEL_CI=1`, which turns every such skip into a failure.

## License

MIT, see [LICENSE](LICENSE). unkernel itself is MIT AND GPL-2.0-only (the Linux kernel); it is installed from npm, not vendored.
