(** Raw shell command parsing helpers for keeper command-shape checks. *)

val parse_cmd_to_ir_opt : string -> Masc_exec.Shell_ir.t option
