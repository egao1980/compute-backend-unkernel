# compute-backend-unkernel

Fallback sandbox backend for [compute-protocol](https://github.com/egao1980/compute-protocol): commands run in [unkernel](https://www.npmjs.com/package/unkernel) (Linux compiled to WebAssembly, run under Node). Portable, no hypervisor or root, for untrusted code where Seatbelt / Landlock or MXC are not available. Not the default: compute is 26–34x slower than native.

**Status:** planned (R4h-4, [compute-protocol#9](https://github.com/egao1980/compute-protocol/issues/9)). Brief: [cl-stack/docs/capabilities/confinement.md § R4h-4](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/confinement.md).

## License

MIT, see [LICENSE](LICENSE).
