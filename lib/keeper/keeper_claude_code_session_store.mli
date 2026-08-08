(** Durable per-Keeper Claude Code session binding. *)

type phase =
  | Claimed of { previous_session_id : string option }
  | Settled of { session_id : string }

type t =
  { runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; last_usage : Runtime_claude_code_cli.usage option
  ; updated_at : float
  }

val path : base_path:string -> keeper_name:string -> (string, string) result
val load : base_path:string -> keeper_name:string -> (t option, string) result

val claim :
  base_path:string ->
  keeper_name:string ->
  expected:t option ->
  runtime_id:string ->
  updated_at:float ->
  (t, string) result

val settle :
  base_path:string ->
  keeper_name:string ->
  expected:t ->
  session_id:string ->
  usage:Runtime_claude_code_cli.usage ->
  updated_at:float ->
  (t, string) result
