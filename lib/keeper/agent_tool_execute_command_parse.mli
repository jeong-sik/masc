(** Dependency-light owner for raw shell command parsing into Shell IR. *)

val parse_cmd_to_ir_opt : string -> Masc_exec.Shell_ir.t option
(** Parse a raw shell command into Shell IR, returning [None] on parse failure. *)
