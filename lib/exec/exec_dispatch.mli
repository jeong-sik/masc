type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

val resolve_arg : Shell_ir.arg -> string
(** Resolve a Shell_ir.arg to a concrete string value. *)

val dispatch : Shell_ir.t -> dispatch_result
(** Execute a [Shell_ir.t] AST directly via Exec_gate without
    going through /bin/bash.  Simple commands use argv-based spawn;
    pipelines chain stdout to stdin across stages. *)

val dispatch_simple : Shell_ir.simple -> dispatch_result
(** Execute a simple command via argv-based spawn. *)

val native_dispatch_enabled : unit -> bool
(** Check [MASC_BASH_NATIVE_DISPATCH] env var.
    - [Some "0"] -> false (always bash fallback)
    - unset or any other value -> true *)
