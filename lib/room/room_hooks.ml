(** Room Hooks — Callback refs for upper-layer dependencies.

    Room modules must not depend on Activity_graph, Board, Council,
    Agent_economy, Relation_materializer, or Oas_worker directly.
    Instead, they call these callback refs which are wired at startup
    by room.ml (the hub module that already depends on everything).

    Defaults are no-ops or error stubs. *)

open Types

(* ============================================ *)
(* Types                                        *)
(* ============================================ *)

(** Activity graph entity — local mirror of Activity_graph.entity_ref
    to avoid dependency on Activity_graph from room sub-modules. *)
type activity_entity = { kind: string; id: string }

(** CP cleanup result — mirrors Cp_cleanup.cleanup_result without
    introducing a dependency on Cp_cleanup (which depends on Room). *)
type cp_cleanup_result = {
  dead_units_removed : int;
  orphaned_units_removed : int;
  operations_archived : int;
  detachments_removed : int;
  intents_removed : int;
}

let empty_cp_result = {
  dead_units_removed = 0;
  orphaned_units_removed = 0;
  operations_archived = 0;
  detachments_removed = 0;
  intents_removed = 0;
}

(* ============================================ *)
(* Callback refs (migrated from room_gc.ml)     *)
(* ============================================ *)

(** Force-release a task — avoids Room_gc → Room_task circular dep. *)
let force_release_task_fn
  : (Room_utils_backend_setup.config -> agent_name:string -> task_id:string -> unit -> string masc_result) ref
  = ref (fun _config ~agent_name:_ ~task_id:_ () ->
      Error (Types.TaskInvalidState "Room_hooks: force_release_task_fn not connected"))

(** CP cleanup callback — avoids Room_gc → Cp_cleanup circular dep. *)
let cp_cleanup_connected = ref false

let cp_cleanup_fn
  : (Room_utils_backend_setup.config -> cp_cleanup_result) ref
  = ref (fun _config -> empty_cp_result)

(* ============================================ *)
(* New callback refs (Phase 4A)                 *)
(* ============================================ *)

(** Activity graph emit — wraps Activity_graph.emit.
    Fire-and-forget: return value is ignored by callers. *)
let activity_emit_fn
  : (Room_utils_backend_setup.config ->
     room_id:string ->
     actor:activity_entity ->
     ?subject:activity_entity ->
     kind:string ->
     payload:Yojson.Safe.t ->
     tags:string list ->
     unit -> unit) ref
  = ref (fun _config ~room_id:_ ~actor:_ ?subject:_ ~kind:_ ~payload:_ ~tags:_ () -> ())

(** Agent economy earn — wraps Agent_economy.earn for task completion credits. *)
let agent_economy_earn_fn
  : (base_path:string -> agent_name:string -> reason:string -> unit) ref
  = ref (fun ~base_path:_ ~agent_name:_ ~reason:_ -> ())

(** Relation materializer: agent leave — wraps Relation_materializer.on_agent_leave. *)
let relation_on_leave_fn
  : (leaving_agent:string -> active_agents:string list -> unit) ref
  = ref (fun ~leaving_agent:_ ~active_agents:_ -> ())

(** Relation materializer: task done — wraps Relation_materializer.on_task_done. *)
let relation_on_task_done_fn
  : (assignee:string -> active_agents:string list -> unit) ref
  = ref (fun ~assignee:_ ~active_agents:_ -> ())

(** Board artifact cleanup — wraps Board_dispatch.list_posts + delete_post.
    Returns number of deleted posts. *)
let cleanup_board_artifacts_fn
  : (unit -> int) ref
  = ref (fun () -> 0)

(** Governance stale case purge — wraps Council.Governance_v2.purge_*.
    Returns (test_cases_purged, artifact_cases_purged). *)
let governance_purge_fn
  : (string -> int * int) ref
  = ref (fun _base_path -> (0, 0))
