type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

val resolve_arg : Shell_ir.arg -> string
(** Resolve a Shell_ir.arg to a concrete string value. *)

val dispatch : ?timeout_sec:float -> Shell_ir.t -> dispatch_result
(** Execute a [Shell_ir.t] AST directly via Exec_gate without
    going through /bin/bash.  Simple commands use argv-based spawn;
    pipelines chain stdout to stdin across stages.  [?timeout_sec]
    overrides the dispatch default for every spawned stage. *)

val dispatch_simple :
  ?timeout_sec:float -> ?stdin_content:string -> Shell_ir.simple -> dispatch_result
(** Execute a simple command via argv-based spawn.  [stdin_content] is
    used by pipeline dispatch when a previous stage's stdout must be
    forwarded without dropping the stage's sandbox target.  [?timeout_sec]
    overrides the dispatch default. *)

val native_dispatch_enabled : unit -> bool
(** Check [MASC_BASH_NATIVE_DISPATCH] env var.
    - [Some "0"] -> false (always bash fallback)
    - unset or any other value -> true *)
