(** Workspace Hooks — Callback refs for upper-layer dependencies.

    Workspace modules must not depend on Activity_graph, Board,
    Economy, Relation_materializer, or Oas_worker directly.
    Instead, they call these callback refs which are wired at startup
    by workspace.ml (the hub module that already depends on everything).

    Defaults are no-ops or error stubs. *)

open Masc_domain

(* ============================================ *)
(* Types                                        *)
(* ============================================ *)

(** Activity graph entity — local mirror of Activity_graph.entity_ref
    to avoid dependency on Activity_graph from workspace sub-modules. *)
type activity_entity = { kind: string; id: string }

type operator_pending_confirm_request =
  { token : string
  ; trace_id : string
  ; actor : string
  ; action_type : string
  ; target_type : string
  ; target_id : string option
  ; payload : Yojson.Safe.t
  ; delegated_tool : string
  ; created_at : string
  ; expires_at : string option
  }

(* ============================================ *)
(* Callback refs (migrated from workspace_gc.ml)     *)
(* ============================================ *)

(** Reconcile an objectively orphaned task — avoids Workspace_gc →
    Workspace_task circular dependency without minting a privileged actor. *)
let reconcile_orphaned_task_fn
  : (Workspace_utils_backend_setup.config ->
     task_id:string ->
     expected_assignee:string ->
     signal:[ `Absent | `Inactive ] ->
     unit ->
     string masc_result) Atomic.t
  = Atomic.make (fun _config ~task_id:_ ~expected_assignee:_ ~signal:_ () ->
      Error
        (Masc_domain.Task
           (Masc_domain.Task_error.InvalidState
              "Workspace_hooks: reconcile_orphaned_task_fn not connected")))

(* ============================================ *)
(* New callback refs (Phase 4A)                 *)
(* ============================================ *)

(** Activity graph emit — wraps Activity_graph.emit.
    Fire-and-forget: return value is ignored by callers. *)
let activity_emit_fn
  : (Workspace_utils_backend_setup.config ->
     actor:activity_entity ->
     ?subject:activity_entity ->
     kind:string ->
     payload:Yojson.Safe.t ->
     tags:string list ->
     unit -> unit) Atomic.t
  = Atomic.make (fun _config ~actor:_ ?subject:_ ~kind:_ ~payload:_ ~tags:_ () -> ())

(** Agent economy earn — wraps Economy.earn for task completion credits. *)
let agent_economy_earn_fn
  : (base_path:string -> agent_name:string -> reason:string -> unit) Atomic.t
  = Atomic.make (fun ~base_path:_ ~agent_name:_ ~reason:_ -> ())

(** Stop keeper keepalive fiber — avoids Workspace_gc → Keeper_keepalive dep.
    Called during zombie cleanup to terminate keeper fibers that would
    otherwise continue making tool calls after agent removal. *)
let stop_keeper_fn
  : (string -> unit) Atomic.t
  = Atomic.make (fun _name -> ())

(** Runtime-visible agents supplied by upper layers such as the keeper
    registry.  Workspace code consumes [Masc_domain.agent] rows without
    depending on the keeper implementation. *)
let runtime_agents_fn
  : (Workspace_utils_backend_setup.config -> Masc_domain.agent list) Atomic.t
  = Atomic.make (fun _config -> [])

(** Relation materializer: agent session end — wraps Relation_materializer.on_agent_session_ended. *)
let relation_on_leave_fn
  : (leaving_agent:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun ~leaving_agent:_ ~active_agents:_ -> ())

(** Relation materializer: task done — wraps Relation_materializer.on_task_done. *)
let relation_on_task_done_fn
  : (assignee:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun ~assignee:_ ~active_agents:_ -> ())

(** Hebbian learning: strengthen collaboration on task completion. *)
let hebbian_on_task_done_fn
  : (Workspace_utils_backend_setup.config ->
     assignee:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun _config ~assignee:_ ~active_agents:_ -> ())

(** Hebbian learning: weaken collaboration on task cancellation. *)
let hebbian_on_task_cancelled_fn
  : (Workspace_utils_backend_setup.config ->
     agent_name:string -> active_agents:string list -> unit) Atomic.t
  = Atomic.make (fun _config ~agent_name:_ ~active_agents:_ -> ())

(** Closed enum for the agent session hook. Replaces the previous
    [event_kind:string] surface (#8605 family): the variant lets the
    compiler enforce exhaustive dispatch on every consumer, and the
    string<->variant mapping is centralised in the helpers below so the
    JSON wire format is owned by this module. *)
type agent_lifecycle_event =
  | Session_bound
  | Session_rebound
  | Session_ended

let agent_lifecycle_event_to_string = function
  | Session_bound -> "session_bound"
  | Session_rebound -> "session_rebound"
  | Session_ended -> "session_ended"

(** Shared observability hook for agent session binding events.
    Upper layers can mirror state transitions to audit, telemetry, and logs
    without introducing circular dependencies into workspace sub-modules. *)
let observe_agent_lifecycle_fn
  : (Workspace_utils_backend_setup.config ->
     agent_id:string ->
     event:agent_lifecycle_event ->
     details:Yojson.Safe.t ->
     unit) Atomic.t
  = Atomic.make
      (fun _config ~agent_id:_ ~event:_ ~details:_ -> ())

(** Shared observability hook for task transitions.
    Used by task modules so every successful state transition is logged
    consistently regardless of which tool or transport triggered it.
    #8605 family: [transition] is the canonical [Masc_domain.task_action]
    variant -- typos at call sites fail to compile and the JSON wire
    format is centralised in [Masc_domain.task_action_to_string]. *)
let observe_task_transition_fn
  : (Workspace_utils_backend_setup.config ->
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
    Workspace sub-modules and server dashboard surfaces. *)
let on_task_mutation_fn
  : (unit -> unit) Atomic.t
  = Atomic.make (fun () -> ())

let operator_pending_confirm_trace_id_fn
  : (string -> string) Atomic.t
  =
  Atomic.make (fun prefix -> prefix ^ "_unwired")

let operator_pending_confirm_upsert_fn
  : (Workspace_utils_backend_setup.config ->
     operator_pending_confirm_request ->
     (unit, string) result)
      Atomic.t
  =
  Atomic.make
    (fun _config _entry ->
      Error "operator pending-confirm callback is not connected")

let operator_pending_confirm_read_result_fn
  : (Workspace_utils_backend_setup.config ->
     (operator_pending_confirm_request list, string) result)
      Atomic.t
  =
  Atomic.make
    (fun _config -> Error "operator pending-confirm callback is not connected")

let operator_pending_confirm_remove_fn
  : (Workspace_utils_backend_setup.config -> string -> (unit, string) result) Atomic.t
  =
  Atomic.make
    (fun _config _token ->
      Error "operator pending-confirm callback is not connected")


(** Auto-subscribe agent to messages on session binding — wraps Subscriptions.SubscriptionStore. *)
let subscribe_messages_fn
  : (subscriber:string -> unit) Atomic.t
  = Atomic.make (fun ~subscriber:_ -> ())

(** #9645: distributed lock acquire failure observability.

    [Workspace_utils_ops.with_distributed_lock] / [..._r] raise
    [Invalid_argument] (or return [Error]) after exhausting the
    retry budget when keeper fleet contention prevents acquiring
    a lock (production observed [tasks:.backlog] starvation under
    16-keeper load).  The error path is the only signal — there
    is no fleet-wide rate metric for "how often does this fail,
    on which key?".

    This hook decouples the emit from [masc.Otel_metric_store] (which
    sits above [masc_workspace] in the dep graph).  [lib/workspace.ml]
    wires it to a Otel_metric_store counter at startup; [masc_workspace]
    callers fire it from the failure branches without taking a
    direct Otel_metric_store dependency. *)
let distributed_lock_acquire_failed_fn
  : (key:string -> attempts:int -> unit) Atomic.t
  = Atomic.make (fun ~key:_ ~attempts:_ -> ())

(** Tool assignment telemetry — wraps Tool_assignment_telemetry.emit_assigned.
    Wired at startup to record which tools were provisioned to which agent. *)
let tool_assigned_fn
  : (agent_id:string ->
     profile:string ->
     tool_list:string list ->
     ?config_hash:string ->
     ?reason:string ->
     unit ->
     string) Atomic.t
  = Atomic.make (fun ~agent_id:_ ~profile:_ ~tool_list:_ ?config_hash:_ ?reason:_ () -> "")

(** #10449: Task completion path observability.

    Issue #10449 documented that 16 task done transitions over 3
    days saw only 1 (6.25%) traverse the [awaiting_verification]
    gate. The [verifier-gate redirect] in [Task.Tool] only fires
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

    - [path]: ["direct_llm_verdict"] / ["via_verification"]
    - [contract_state]: ["no_contract"] / ["empty_contract"] /
      ["with_contract"]

    Cardinality is bounded at ~4 × 3 × fleet_size series, safe
    for Otel_metric_store.  Emit lives in [lib/workspace.ml] to avoid a
    [masc_workspace → Otel_metric_store] dep cycle. *)
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
    [from_status], but a Otel_metric_store counter is the missing surface:
    operators cannot alert on auto-release rate or split it by
    keeper from a JSONL tail alone.  The split by [from_status]
    matters because [Claimed → Todo] (just claimed, no work yet)
    and [InProgress → Todo] (mid-work, lost progress) are
    operationally distinct symptoms.

    Cardinality bounded by fleet size (~10 keepers) ×
    [from_status] (claimed | in_progress) = ~20 series.  Emit at
    [lib/workspace.ml] to avoid a [masc_workspace → Otel_metric_store] dep cycle. *)
let task_auto_release_observed_fn
  : (agent_name:string -> from_status:string -> unit) Atomic.t
  = Atomic.make (fun ~agent_name:_ ~from_status:_ -> ())

(** Wall-clock latency of [Workspace_broadcast.broadcast] including
    [next_seq] (state.json file lock + read + write), agent.json read
    for the cache-invariant check, msg.json write, [backend_publish],
    [emit_message_activity], and the [on_broadcast_mention] callback.
    Labelled by [msg_type] so [cache_invalidated] follow-ups (which
    skip the agent.json read + use the rewritten content) are
    distinguishable from regular broadcasts.  Default no-op; emit
    lives in [lib/workspace.ml] to avoid a [masc_workspace → Otel_metric_store] dep
    cycle. *)
let workspace_broadcast_observed_fn
  : (msg_type:string -> elapsed_s:float -> unit) Atomic.t
  = Atomic.make (fun ~msg_type:_ ~elapsed_s:_ -> ())

(** RFC-0040: sender-side mention dedup decision counter.  Default
    no-op; emit lives in [lib/workspace.ml] to avoid a
    [masc_workspace → Otel_metric_store] dep cycle.
    Outcome vocabulary: [skipped|passed|no_target|bypassed]. *)
let mention_dedup_decision_fn
  : (outcome:string -> unit) Atomic.t
  = Atomic.make (fun ~outcome:_ -> ())

(** #13460: stale task-state cache emission observability.
    Workspace sub-modules fire this when they replace a stale active-task
    broadcast/mention with a cache invalidation message. [lib/workspace.ml]
    clears workspace-owned task caches and wires observability to Otel_metric_store
    to avoid a [masc_workspace -> Otel_metric_store] dependency. *)
let cache_desync_cleared_fn
  : (Workspace_utils_backend_setup.config ->
     module_name:string -> task_id:string -> status:string -> unit) Atomic.t
  = Atomic.make (fun _config ~module_name:_ ~task_id:_ ~status:_ -> ())

let workspace_telemetry_drop_fn
  : (Workspace_telemetry_drop_event.t -> unit) Atomic.t
  = Atomic.make (fun _ -> ())

let active_agents_change_fn
  : ([ `Inc | `Dec ] -> unit) Atomic.t
  = Atomic.make (fun _ -> ())

let telemetry_observe_failure_fn
  : (string -> unit) Atomic.t
  = Atomic.make (fun _ -> ())

let get_default_runtime_id_fn
  : (unit -> string) Atomic.t
  = Atomic.make (fun () -> failwith "Workspace_hooks: get_default_runtime_id_fn not connected")

(* Optional: [None] means "use the global default runtime". Defaults to a
   None-returning thunk (not a failwith) so unconnected test contexts fall back
   to the default instead of crashing. *)
let get_cross_verifier_runtime_id_fn
  : (unit -> string option) Atomic.t
  = Atomic.make (fun () -> None)

let record_task_metric_fn
  : (Workspace_utils_backend_setup.config ->
     agent_id:string ->
     task_id:string ->
     started_at:float ->
     completed_at:float option ->
     success:bool ->
     error_message:string option ->
     collaborators:string list ->
     handoff_from:string option ->
     handoff_to:string option ->
     unit) Atomic.t
  = Atomic.make (fun _config ~agent_id:_ ~task_id:_ ~started_at:_ ~completed_at:_ ~success:_ ~error_message:_ ~collaborators:_ ~handoff_from:_ ~handoff_to:_ -> ())

let record_thompson_result_fn
  : (agent_name:string -> success:bool -> reason:string option -> unit) Atomic.t
  = Atomic.make (fun ~agent_name:_ ~success:_ ~reason:_ -> ())

let push_task_event_fn
  : (event_type:string -> details:(string * Yojson.Safe.t) list -> unit) Atomic.t
  = Atomic.make (fun ~event_type:_ ~details:_ -> ())

let verification_submit_request_fn
  : (Workspace_utils_backend_setup.config ->
     task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     evidence_refs:string list ->
     (unit, string) result) Atomic.t
  = Atomic.make
      (fun _config ~task:_ ~assignee:_ ~verification_id:_ ~evidence_refs:_ ->
         Ok ())

let verification_record_verdict_fn
  : (Workspace_utils_backend_setup.config ->
     task_id:string ->
     verifier:string ->
     verification_id:string ->
     decision:[ `Approve of string | `Reject of string ] ->
     (unit, string) result) Atomic.t
  = Atomic.make
      (fun _config ~task_id:_ ~verifier:_ ~verification_id:_ ~decision:_ ->
         Ok ())

(* RFC-0221 §3.1: compensation hook for atomic submit. Filled at boot to delete
   a verification record whose task_status commit failed. Default is a no-op so
   the workspace layer never hard-depends on the verification store. *)
let verification_delete_request_fn
  : (Workspace_utils_backend_setup.config ->
     verification_id:string ->
     (unit, string) result) Atomic.t
  = Atomic.make (fun _config ~verification_id:_ -> Ok ())

let verification_notify_submit_fn
  : (Workspace_utils_backend_setup.config ->
     task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     evidence_refs:string list ->
     unit) Atomic.t
  = Atomic.make
      (fun _config ~task:_ ~assignee:_ ~verification_id:_ ~evidence_refs:_ ->
         ())

let verification_notify_verdict_fn
  : (task_id:string ->
     verifier:string ->
     verification_id:string ->
     decision:[ `Approve of string | `Reject of string ] ->
     unit) Atomic.t
  = Atomic.make
      (fun ~task_id:_ ~verifier:_ ~verification_id:_ ~decision:_ -> ())

let is_admin_agent_fn
  : (base_path:string -> agent_name:string -> bool) Atomic.t
  = Atomic.make (fun ~base_path:_ ~agent_name:_ -> false)
