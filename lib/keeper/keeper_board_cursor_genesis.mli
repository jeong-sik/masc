(** Establish the current-generation durable Board cursor before a Keeper is
    admitted. This is genesis from the current Board head; it never reads or
    converts an older reaction-ledger generation. *)

type error =
  | Shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Restore_failed of Keeper_reaction_ledger.board_cursor_restore_error
  | Persist_failed of string

val error_to_string : error -> string

val ensure_with :
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
  current_post_cursor:(unit -> float * string option) ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (unit, error) result

val ensure :
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
  base_path:string ->
  keeper_name:string ->
  unit ->
  (unit, error) result
