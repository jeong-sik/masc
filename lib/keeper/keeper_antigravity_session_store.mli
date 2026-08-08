(** Durable per-Keeper Antigravity conversation binding. *)

type phase =
  | Claimed of { previous_conversation_id : string option }
  | Settled of { conversation_id : string }

type t =
  { runtime_id : string
  ; phase : phase
  ; turn_count : int
  ; last_usage : Runtime_antigravity_cli.usage option
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
  conversation_id:string ->
  usage:Runtime_antigravity_cli.usage ->
  updated_at:float ->
  (t, string) result
