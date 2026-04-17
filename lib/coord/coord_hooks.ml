(** Coord Hooks — Callback refs for upper-layer dependencies.

    Coord modules must not depend on Activity_graph, Board,
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

(* ============================================ *)
(* Callback refs (migrated from room_gc.ml)     *)
(* ============================================ *)

(** Force-release a task — avoids Coord_gc → Coord_task circular dep. *)
let force_release_task_fn
  : (Coord_utils_backend_setup.config -> agent_name:string -> task_id:string -> unit -> string masc_result) Atomic.t
  = Atomic.make (fun _config ~agent_name:_ ~task_id:_ () ->
      Error (Types.TaskInvalidState "Coord_hooks: force_release_task_fn not connected"))

(* ============================================ *)
(* New callback refs (Phase 4A)                 *)
(* ============================================ *)

(** Activity graph emit — wraps Activity_graph.emit.
    Fire-and-forget: return value is ignored by callers. *)
let activity_emit_fn
  : (Coord_utils_backend_setup.config ->
     actor:activity_entity ->
     ?subject:activity_entity ->
     kind:string ->
     payload:Yojson.Safe.t ->
     tags:string list ->
     unit -> unit) Atomic.t
  = Atomic.make (fun _config ~actor:_ ?subject:_ ~kind:_ ~payload:_ ~tags:_ () -> ())

(** Agent economy earn — wraps Agent_economy.earn for task completion credits. *)
let agent_economy_earn_fn
  : (base_path:string -> agent_name:string -> reason:string -> unit) Atomic.t
  = Atomic.make (fun ~base_path:_ ~agent_name:_ ~reason:_ -> ())

(** Stop keeper keepalive fiber — avoids Coord_gc → Keeper_keepalive dep.
    Called during zombie cleanup to terminate keeper fibers that would
    otherwise continue making tool calls after agent removal. *)
let stop_keeper_fn
  : (string -> unit) Atomic.t
  = Atomic.make (fun _name -> ())

(** Relation materializer: agent leave — wraps Relation_materializer.on_agent_leave. *)
let relation_on_leave_fn
  : (leaving_agent:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun ~leaving_agent:_ ~active_agents:_ -> ())

(** Relation materializer: task done — wraps Relation_materializer.on_task_done. *)
let relation_on_task_done_fn
  : (assignee:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun ~assignee:_ ~active_agents:_ -> ())

(** Hebbian learning: strengthen collaboration on task completion. *)
let hebbian_on_task_done_fn
  : (Coord_utils_backend_setup.config ->
     assignee:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun _config ~assignee:_ ~active_agents:_ -> ())

(** Hebbian learning: weaken collaboration on task cancellation. *)
let hebbian_on_task_cancelled_fn
  : (Coord_utils_backend_setup.config ->
     agent_name:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun _config ~agent_name:_ ~active_agents:_ -> ())

(** Shared observability hook for join/rejoin/leave events.
    Upper layers can mirror state transitions to audit, telemetry, and logs
    without introducing circular dependencies into room sub-modules. *)
let observe_agent_lifecycle_fn
  : (Coord_utils_backend_setup.config ->
     agent_id:string ->
     event_kind:string ->
     details:Yojson.Safe.t ->
     unit) Atomic.t
  = Atomic.make
      (fun _config ~agent_id:_ ~event_kind:_ ~details:_ -> ())

(** Shared observability hook for task transitions.
    Used by room task modules so every successful state transition is logged
    consistently regardless of which tool or transport triggered it. *)
let observe_task_transition_fn
  : (Coord_utils_backend_setup.config ->
     agent_name:string ->
     task_id:string ->
     transition:string ->
     details:Yojson.Safe.t ->
     unit) Atomic.t
  = Atomic.make
      (fun _config ~agent_name:_ ~task_id:_ ~transition:_
           ~details:_ -> ())

(** Board artifact cleanup — wraps Board_dispatch.list_posts + delete_post.
    Returns number of deleted posts. *)
let cleanup_board_artifacts_fn
  : (unit -> int) Atomic.t
  = Atomic.make (fun () -> 0)

(** Invalidate dashboard execution cache on task mutation (add, transition).
    Wired by server bootstrap to avoid circular dependency between
    Coord sub-modules and server dashboard surfaces. *)
let on_task_mutation_fn
  : (unit -> unit) Atomic.t
  = Atomic.make (fun () -> ())


(** Auto-subscribe agent to messages on join — wraps Subscriptions.SubscriptionStore. *)
let subscribe_messages_fn
  : (subscriber:string -> unit) Atomic.t
  = Atomic.make (fun ~subscriber:_ -> ())
