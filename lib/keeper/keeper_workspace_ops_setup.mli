(** Shared setup for Grep shell operation handlers. *)

val coreutils : Host_config.coreutils
val metric_bash_history_append_failures : string

val observe_history_append
  :  root:string
  -> keeper_name:string
  -> Masc_exec.Bash_history.history_entry
  -> unit

val render_completed_process_result
  :  root:string
  -> keeper_name:string
  -> op:string
  -> ?cwd:string
  -> cmd:string
  -> ?extra:(string * Yojson.Safe.t) list
  -> Unix.process_status
  -> string
  -> string
