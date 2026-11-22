(defsystem "compute-backend-unkernel"
  :version "0.1.0"
  :description "Fallback sandbox backend for compute-protocol: Linux compiled to WebAssembly (unkernel) under Node, no hypervisor or root"
  :author "egao1980"
  :license "MIT"
  :depends-on ("compute-protocol")
  :serial t
  :pathname "src"
  :components ((:file "package")))
