val sanitize_command_for_log_of_ir :
  fallback_cmd:string -> Masc_exec.Shell_ir.t -> string
val sanitize_parts : string list -> string
(** Redact one command already split into words: a word after a sensitive
    flag and any [key=value] word holding a secret become [[REDACTED]].
    Matching is case-insensitive. *)
val truncate_for_log : ?max_len:int -> string -> string
