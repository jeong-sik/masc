(** Command-shape classifier for {!Keeper_shell_bash}. *)

val shell_ir_shape_scan_text : string -> string

val shell_ir_parse_failure_shape_block :
  string -> Keeper_shell_bash_shape_messages.bash_shape_block option

val keeper_bash_shape_block :
  string -> Keeper_shell_bash_shape_messages.bash_shape_block option
