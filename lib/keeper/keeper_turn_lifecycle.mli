(** Keeper_turn_lifecycle — keeper shutdown handlers.

    Extracted from keeper_turn.ml. *)

type tool_result = Keeper_types_profile.tool_result

(** Handle the [masc_keeper_down] MCP tool call.  A retained shutdown persists
    its operator-paused next-boot intent before stopping the live registry
    entry; full removal may also remove meta and/or the session directory. *)
val handle_keeper_down :
  _ Keeper_types_profile.context -> Yojson.Safe.t -> tool_result

(** RFC-0182 §3.1 — ctx-free entry point for keeper_dispatch_ref path. *)
val handle_keeper_down_config :
  config:Workspace.config -> Yojson.Safe.t -> tool_result

val register_remove_pending_confirms_by_target :
  (Workspace.config ->
   target_type:string ->
   target_id:string option ->
   (int, string) result) ->
  unit

(** Test-only hooks for the Atomic-backed callback. *)
module For_testing : sig
  val remove_pending_confirms_by_target
    : config:Workspace.config ->
      target_type:string ->
      target_id:string option ->
      (int, string) result

  val reset_remove_pending_confirms_by_target : unit -> unit
end
