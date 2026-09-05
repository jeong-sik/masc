(** Workspace Hooks — Callback refs for upper-layer dependencies.

    Workspace modules must not depend on Activity_graph, Board,
    Relation_materializer or the runtime execution boundary directly.
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
  { confirm_token : string
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

(** Runtime-visible agents supplied by upper layers such as the keeper
    registry.  Workspace code consumes [Masc_domain.agent] rows without
    depending on the keeper implementation. *)
let runtime_agents_fn
  : (Workspace_utils_backend_setup.config -> Masc_domain.agent list) Atomic.t
  = Atomic.make (fun _config -> [])

let keeper_registered_fn
  : (base_path:string -> agent_name:string -> bool) Atomic.t
  = Atomic.make (fun ~base_path:_ ~agent_name:_ -> false)

(* Default allows every target so embedded contexts without the runtime wiring
   keep creating schedules; the runtime installs the durable-metadata reader at
   boot. Tool_schedule stays free of static keeper dependencies (RFC-0194). *)
let schedule_wake_target_registered_fn
  : (Workspace_utils_backend_setup.config -> string -> (bool, string) result) Atomic.t
  = Atomic.make (fun _config _keeper_name -> Ok true)

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

type task_terminal_delivery =
  | Task_terminal_delivered
  | Task_terminal_delivery_degraded of { kind : string; detail : string }

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

(** Invalidate dashboard execution cache after an authoritative task backlog or
    goal-link commit. Wired by server bootstrap to avoid a dependency from
    Workspace sub-modules back to server dashboard surfaces. *)
let on_task_mutation_fn
  : (unit -> unit) Atomic.t
  = Atomic.make (fun () -> ())

let on_workspace_message_mutation_fn
  : (Workspace_utils_backend_setup.config ->
     request_id:string ->
     mention_delivery:Masc_domain.message_mention_delivery ->
     unit)
      Atomic.t
  = Atomic.make (fun _config ~request_id:_ ~mention_delivery:_ -> ())

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

(** Wall-clock latency of a successfully committed
    [Workspace_broadcast.broadcast], including
    [next_seq] (state.json file lock + read + write), agent.json read
    for the cache-invariant check, msg.json write, [backend_publish],
    [emit_message_activity], and the [on_broadcast_mention] callback.
    Labelled by [msg_type] so [cache_invalidated] follow-ups (which
    skip the agent.json read + use the rewritten content) are
    distinguishable from regular broadcasts. Authoritative write failures do
    not emit this success observation. Default no-op; emit
    lives in [lib/workspace.ml] to avoid a [masc_workspace → Otel_metric_store] dep
    cycle. *)
let workspace_broadcast_observed_fn
  : (msg_type:string -> elapsed_s:float -> unit) Atomic.t
  = Atomic.make (fun ~msg_type:_ ~elapsed_s:_ -> ())

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

(* The completion-authority evaluator's runtime comes only from the published
   [verifier_exact] exact-output lane (RFC-0361 D7(a)): admitted slot ids in
   frozen declaration order. The unconnected default is an explicit [Error] so
   an unwired process leaves the review visibly deferred instead of silently
   picking a runtime. *)
let get_verifier_exact_lane_slot_ids_fn
  : (unit -> (string list, string) result) Atomic.t
  = Atomic.make (fun () ->
      Error "Workspace_hooks: get_verifier_exact_lane_slot_ids_fn not connected")

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

let push_task_event_fn
  : (event_type:string -> details:(string * Yojson.Safe.t) list -> unit) Atomic.t
  = Atomic.make (fun ~event_type:_ ~details:_ -> ())

let task_terminal_committed_fn
  : (Workspace_utils_backend_setup.config ->
     agent_name:string ->
     task_id:string ->
     task_terminal_delivery) Atomic.t
  =
  Atomic.make
    (fun _config ~agent_name:_ ~task_id:_ -> Task_terminal_delivered)

let verification_submit_request_fn
  : (Workspace_utils_backend_setup.config ->
     task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     claim:Masc_domain.verification_claim ->
     (unit, string) result) Atomic.t
  = Atomic.make
      (fun _config ~(task : Masc_domain.task) ~assignee ~verification_id ~claim:_ ->
         Error
           (Printf.sprintf
              "verification request persistence hook is not installed (task=%s assignee=%s verification_id=%s)"
              task.id
              assignee
              verification_id))

(* RFC-0221 §3.1: compensation hook for atomic submit. Filled at boot to delete
   a verification record whose task_status commit failed. A missing hook is an
   explicit error: a submit must never leave the caller believing that the
   verification record was persisted when the storage boundary is absent. *)
let verification_delete_request_fn
  : (Workspace_utils_backend_setup.config ->
     verification_id:string ->
     (unit, string) result) Atomic.t
  = Atomic.make (fun _config ~verification_id ->
      Error
        (Printf.sprintf
           "verification request deletion hook is not installed (verification_id=%s)"
           verification_id))

let verification_notify_submit_fn
  : (Workspace_utils_backend_setup.config ->
     task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     claim:Masc_domain.verification_claim ->
     unit) Atomic.t
  = Atomic.make
      (fun _config ~(task : Masc_domain.task) ~assignee ~verification_id ~claim:_ ->
         Log.Misc.warn
           "verification request notification hook is not installed task_id=%s verification_id=%s producer=%s"
           task.id
           verification_id
           assignee)

let verification_submitted_fn
  : (Workspace_utils_backend_setup.config ->
     task:Masc_domain.task ->
     assignee:string ->
     verification_id:string ->
     unit) Atomic.t
  = Atomic.make
      (fun _config ~(task : Masc_domain.task) ~assignee ~verification_id ->
         Log.Misc.warn
           "verification submitted without an installed system LLM completion authority lane task_id=%s verification_id=%s producer=%s"
           task.id
           verification_id
           assignee)

(* RFC-0387 stage 2: the goal-side analogue of [verification_submitted_fn].
   The uninstalled default is loud for the same reason — a durable pending
   request with no lane draining it is exactly the gate-without-caller wedge
   the stage was split to avoid. *)
let goal_verification_pending_fn
  : (Workspace_utils_backend_setup.config -> goal_id:string -> unit) Atomic.t
  = Atomic.make
      (fun _config ~goal_id ->
         Log.Misc.warn
           "goal verification request committed without an installed goal verifier lane goal_id=%s"
           goal_id)

let verification_notify_verdict_fn
  : (task_id:string ->
     authority:Masc_domain.completion_authority ->
     verification_id:string ->
     decision:[ `Approve of string | `Reject of string ] ->
     unit) Atomic.t
  = Atomic.make
      (fun ~task_id ~authority ~verification_id ~decision ->
         let decision_kind =
           match decision with
           | `Approve _ -> "approve"
           | `Reject _ -> "reject"
         in
         Log.Misc.warn
           "verification verdict notification hook is not installed task_id=%s verification_id=%s authority_kind=%s authority_actor=%s decision=%s"
           task_id
           verification_id
           (Masc_domain.completion_authority_kind authority)
           (Masc_domain.completion_authority_actor authority)
           decision_kind)

