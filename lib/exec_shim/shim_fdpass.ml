(* shim_fdpass.ml — SCM_RIGHTS descriptor passing for masc-exec-shim.
   The C stub lives beside this module because this module declares its
   externals; see fdpass_stub.c and
   docs/superpowers/specs/2026-09-14-refused-observe-observation-path-design.md
   (task-1568 phase 2). *)

external send_fd : Unix.file_descr -> Unix.file_descr -> unit
  = "ocaml_shim_send_fd"

external recv_fd : Unix.file_descr -> Unix.file_descr = "ocaml_shim_recv_fd"
