(** Keeper lifecycle tools submit durable, non-blocking shutdown operations. *)

type tool_result = Keeper_types_profile.tool_result

val handle_keeper_down :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

val register_remove_pending_confirms_by_target :
  (Workspace.config ->
   target_type:string ->
   target_id:string option ->
   (int, string) result) ->
  unit

module For_testing : sig
  val remove_pending_confirms_by_target :
    config:Workspace.config ->
    target_type:string ->
    target_id:string option ->
    (int, string) result

  val reset_remove_pending_confirms_by_target : unit -> unit
end
