(** Keeper_turn_lifecycle — keeper shutdown handlers.

    Extracted from keeper_turn.ml. *)

type tool_result = Keeper_types_profile.tool_result

(** Handle [masc_keeper_down] as a lane-local transaction: persist paused
    intent, cancel and join the concrete lane fiber, settle an interrupted turn
    and task ownership, then commit cleanup and unregister.  A failed stage
    returns an explicit retryable partial-failure payload and leaves the paused
    lane registered. *)
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
