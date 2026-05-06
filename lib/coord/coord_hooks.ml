(** Coord Hooks — Callback refs for upper-layer dependencies.

    Coord modules must not depend on Activity_graph, Board,
    Agent_economy, Relation_materializer, or Oas_worker directly.
    Instead, they call these callback refs which are wired at startup
    by room.ml (the hub module that already depends on everything).

    Defaults are no-ops or error stubs. *)

open Masc_domain

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
      Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState "Coord_hooks: force_release_task_fn not connected")))

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

(** Closed enum for the agent lifecycle hook. Replaces the previous
    [event_kind:string] surface (#8605 family): the variant lets the
    compiler enforce exhaustive dispatch on every consumer, and the
    string<->variant mapping is centralised in the helpers below so the
    JSON wire format ("join" / "rejoin" / "leave") stays exactly the
    same. *)
type agent_lifecycle_event =
  | Lifecycle_join
  | Lifecycle_rejoin
  | Lifecycle_leave

let agent_lifecycle_event_to_string = function
  | Lifecycle_join -> "join"
  | Lifecycle_rejoin -> "rejoin"
  | Lifecycle_leave -> "leave"

(** Shared observability hook for join/rejoin/leave events.
    Upper layers can mirror state transitions to audit, telemetry, and logs
    without introducing circular dependencies into room sub-modules. *)
let observe_agent_lifecycle_fn
  : (Coord_utils_backend_setup.config ->
     agent_id:string ->
     event:agent_lifecycle_event ->
     details:Yojson.Safe.t ->
     unit) Atomic.t
  = Atomic.make
      (fun _config ~agent_id:_ ~event:_ ~details:_ -> ())

(** Shared observability hook for task transitions.
    Used by room task modules so every successful state transition is logged
    consistently regardless of which tool or transport triggered it.
    #8605 family: [transition] is the canonical [Masc_domain.task_action]
    variant -- typos at call sites fail to compile and the JSON wire
    format is centralised in [Masc_domain.task_action_to_string]. *)
let observe_task_transition_fn
  : (Coord_utils_backend_setup.config ->
     agent_name:string ->
     task_id:string ->
     transition:task_action ->
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

(** #9795: FSM drift observability.  [Coord_task.transition]
    signals TLA+ KeeperTaskInterlock violations (currently the
    [Claimed_to_done_skip] branch) through this hook; [lib/coord.ml]
    wires it to a Prometheus counter emit at startup.  Keeping the
    hook here avoids a [masc_coord → masc_mcp.Prometheus]
    dependency cycle. *)
let fsm_drift_observer_fn
  : (variant:string -> force:bool -> agent_name:string -> unit) Atomic.t
  = Atomic.make (fun ~variant:_ ~force:_ ~agent_name:_ -> ())

(** #9645: distributed lock acquire failure observability.

    [Coord_utils_ops.with_distributed_lock] / [..._r] raise
    [Invalid_argument] (or return [Error]) after exhausting the
    retry budget when keeper fleet contention prevents acquiring
    a lock (production observed [tasks:.backlog] starvation under
    16-keeper load).  The error path is the only signal — there
    is no fleet-wide rate metric for "how often does this fail,
    on which key?".

    This hook decouples the emit from [masc_mcp.Prometheus] (which
    sits above [masc_coord] in the dep graph).  [lib/coord.ml]
    wires it to a Prometheus counter at startup; [masc_coord]
    callers fire it from the failure branches without taking a
    direct Prometheus dependency. *)
let distributed_lock_acquire_failed_fn
  : (key:string -> attempts:int -> unit) Atomic.t
  = Atomic.make (fun ~key:_ ~attempts:_ -> ())

(** Tool assignment telemetry — wraps Tool_assignment_telemetry.emit_assigned.
    Wired at startup to record which tools were provisioned to which agent. *)
let tool_assigned_fn
  : (agent_id:string ->
     profile:string ->
     ?preset:string ->
     tool_list:string list ->
     ?allow_set:string list ->
     ?deny_set:string list ->
     ?config_hash:string ->
     ?reason:string ->
     unit ->
     string) Atomic.t
  = Atomic.make (fun ~agent_id:_ ~profile:_ ?preset:_ ~tool_list:_ ?allow_set:_ ?deny_set:_ ?config_hash:_ ?reason:_ () -> "")

(** #10449: Task completion path observability.

    Issue #10449 documented that 16 task done transitions over 3
    days saw only 1 (6.25%) traverse the [awaiting_verification]
    gate. The [verifier-gate redirect] in [Tool_task] only fires
    when [task.contract] has a non-empty [completion_contract] or
    [required_evidence] list, so tasks created without contracts
    bypass verification entirely.

    The pre-existing [fsm_drift_observer_fn] only counts the
    [Claimed → Done] skip pattern (skipping [in_progress]); it
    does not split by contract presence, so operators cannot tell
    whether the bypass rate comes from missing contracts
    (creation-side problem) or from the redirect mis-firing
    (gate-side problem).

    This hook fires once per successful transition into [Done] and
    classifies the path along two axes:

    - [path]: ["claimed_to_done_skip"] / ["in_progress_to_done"] /
      ["via_verification"] / ["forced_done"]
    - [contract_state]: ["no_contract"] / ["empty_contract"] /
      ["with_contract"]

    Cardinality is bounded at ~4 × 3 × fleet_size series, safe
    for Prometheus.  Emit lives in [lib/coord.ml] to avoid a
    [masc_coord → Prometheus] dep cycle. *)
let task_completion_path_observed_fn
  : (path:string -> contract_state:string -> agent_name:string -> unit) Atomic.t
  = Atomic.make (fun ~path:_ ~contract_state:_ ~agent_name:_ -> ())

(** #10421: task_claim_next implicit auto-release observability.

    When a keeper calls [task_claim_next] while still holding a
    previous claim, the scheduler implicitly transitions that prior
    claim back to [Todo] before issuing the new one.  Field log
    showed 43 [claimed → todo] transitions vs 24 [todo → claimed]
    in a single day (179% release/claim ratio), with only 1/71
    transitions reaching [done] — the same task hot-potatoed up to
    5x as keepers churned through claim_next without finishing.

    The structured event already carries [reason] and
    [from_status], but a Prometheus counter is the missing surface:
    operators cannot alert on auto-release rate or split it by
    keeper from a JSONL tail alone.  The split by [from_status]
    matters because [Claimed → Todo] (just claimed, no work yet)
    and [InProgress → Todo] (mid-work, lost progress) are
    operationally distinct symptoms.

    Cardinality bounded by fleet size (~10 keepers) ×
    [from_status] (claimed | in_progress) = ~20 series.  Emit at
    [lib/coord.ml] to avoid a [masc_coord → Prometheus] dep cycle. *)
let task_auto_release_observed_fn
  : (agent_name:string -> from_status:string -> unit) Atomic.t
  = Atomic.make (fun ~agent_name:_ ~from_status:_ -> ())

(** #13460: stale task-state cache emission observability.
    Coord sub-modules fire this when they replace a stale active-task
    broadcast/mention with a cache invalidation message. [lib/coord.ml]
    clears coord-owned task caches and wires observability to Prometheus
    to avoid a [masc_coord -> Prometheus] dependency. *)
let cache_desync_cleared_fn
  : (Coord_utils_backend_setup.config ->
     module_name:string -> task_id:string -> status:string -> unit) Atomic.t
  = Atomic.make (fun _config ~module_name:_ ~task_id:_ ~status:_ -> ())

(** task-103: Auto-provision a sandbox worktree on successful task claim.

    [Coord_task.claim_task_r] flips a task to [Claimed] but does not create
    the per-task git worktree the keeper subprocess will need (the LLM is
    expected to invoke [masc_worktree_create] explicitly, but in practice
    keepers often skip that step and immediately try to [cd] into the
    worktree path inside docker, which fails with [fatal: not a git
    repository: .../keeper-<agent>-<task>]).

    This hook is called best-effort right after a successful claim. The
    consumer (lib/keeper) decides whether to actually provision based on
    keeper [sandbox_profile] (only [Docker] keepers benefit; local-host
    keepers operate on the project root directly). Failures are logged but
    do not block the claim — claim semantics stay independent of sandbox
    state.

    Wired in [lib/keeper/keeper_runtime.ml] at startup; the default no-op
    keeps [masc_coord] free of a direct dependency on [masc_mcp]. *)
let claim_post_provision_fn
  : (Coord_utils_backend_setup.config -> agent_name:string -> task_id:string -> unit) Atomic.t
  = Atomic.make (fun _ ~agent_name:_ ~task_id:_ -> ())

let claim_post_provision_failed_fn
  : (site:string ->
     agent_name:string ->
     task_id:string ->
     error:string ->
     unit) Atomic.t
  = Atomic.make
      (fun ~site:_ ~agent_name:_ ~task_id:_ ~error:_ -> ())

let observe_claim_post_provision_failure ~site ~agent_name ~task_id exn =
  let error = Printexc.to_string exn in
  (try
     (Atomic.get claim_post_provision_failed_fn)
       ~site ~agent_name ~task_id ~error
   with _ -> ());
  (try
     Log.RoomTask.warn
       "claim_post_provision failed site=%s agent=%s task=%s err=%s"
       site agent_name task_id error
   with _ -> ())
