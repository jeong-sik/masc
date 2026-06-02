val sanitize_command_for_log : string -> string
val sanitize_command_for_log_of_ir :
  fallback_cmd:string -> Masc_exec.Shell_ir.t -> string
val truncate_for_log : ?max_len:int -> string -> string
