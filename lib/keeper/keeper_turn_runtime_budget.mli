(* Keeper_turn_runtime_budget — runtime execution types, fail-open rotation,
   provider timeout resolution, context overflow observation, keeper pause/resume
   sync, partial-commit continue gate, and context budget resolution.

   Public sub-module included by [Keeper_unified_turn]. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
module EC = Keeper_error_classify

type runtime_execution = {
  runtime_id : string;
  max_context_resolution : max_context_resolution;
  max_context : int;
  temperature : float;
  max_tokens : int option;
}

val next_fail_open_runtime_for_turn :
  base_runtime:string ->
  effective_runtime:string ->
  attempted_runtimes:string list ->
  Agent_sdk.Error.sdk_error ->
  EC.degraded_retry option
(** Same-turn retries use the generic keeper-assignable rotation catalog plus
    any explicit [fallback_runtime] hint. *)

val sdk_error_kind : Agent_sdk.Error.sdk_error -> string

val provider_timeout_guard_sec : float
(** Provider startup guard floor (seconds). *)

val min_provider_timeout_budget_sec : float
(** Minimum provider timeout budget (seconds). *)

type provider_timeout_budget = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  source : string;
}

val provider_timeout_budget_to_yojson :
  provider_timeout_budget -> Yojson.Safe.t

val resolve_bounded_provider_timeout_budget_with_turn_budget :
  allow_wall_clock_retry_budget:bool ->
  is_retry:bool ->
  estimated_input_tokens:int ->
  remaining_turn_budget_s:float ->
  provider_timeout_budget
(** Resolves the per-provider timeout plan. The outer keeper turn budget is
    telemetry here, not an admission gate; provider liveness, stream idle, and
    idle-turn limits own attempt termination. *)

val allow_wall_clock_retry_budget_for_attempt :
  is_retry:bool ->
  degraded_rotation_first_attempt:bool ->
  attempt:int ->
  attempted_runtimes:string list ->
  bool

val degraded_retry_slot_phase_budget_sec : float
(** Maximum outer-slot hold time before degraded runtime rotation is
    suppressed. This is a guardrail for #12888: once the productive
    phase has already consumed this much wall clock, rotation should end
    the cycle instead of holding the same slot for another provider
    attempt. provider-timeout failures may still rotate to the next
    degraded runtime when retry budget remains, because the failed attempt
    already represents the budgeted provider wait. *)

val degraded_retry_slot_phase_available :
  time_spent_in_turn_s:float -> bool


type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_slot_phase_exhausted of EC.degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

type 'a degraded_retry_prepare_result =
  | Degraded_retry_prepared of {
      retry : EC.degraded_retry;
      reason : string;
      next : 'a;
    }
  | Degraded_retry_setup_failed of {
      retry : EC.degraded_retry;
      reason : string;
      fail_open_err : Agent_sdk.Error.sdk_error;
    }

type 'a degraded_retry_step =
  | Degraded_retry_step_not_allowed
  | Degraded_retry_step_slot_phase_exhausted of {
      retry : EC.degraded_retry;
      reason : string;
    }
  | Degraded_retry_step_setup_failed of {
      retry : EC.degraded_retry;
      reason : string;
      fail_open_err : Agent_sdk.Error.sdk_error;
    }
  | Degraded_retry_step_prepared of {
      retry : EC.degraded_retry;
      reason : string;
      next : 'a;
    }

val next_fail_open_runtime_for_turn_with_budget :
  base_runtime:string ->
  effective_runtime:string ->
  attempted_runtimes:string list ->
  estimated_input_tokens:int ->
  ?time_spent_in_turn_s:float ->
  remaining_turn_budget_s:float ->
  Agent_sdk.Error.sdk_error ->
  degraded_retry_budget_decision

val prepare_degraded_retry_allowed :
  current_runtime_id:string ->
  attempt:int ->
  err:Agent_sdk.Error.sdk_error ->
  retry:EC.degraded_retry ->
  publish_cascade_resolution:
    (runtime_id:string ->
     decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
     reason:string ->
     next_runtime:string option ->
     attempt:int ->
     Agent_sdk.Error.sdk_error ->
     unit) ->
  emit_runtime_selected:(runtime_id:string -> fallback_reason:string -> unit) ->
  emit_runtime_rotation:(from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
  setup_runtime:(string -> ('a, Agent_sdk.Error.sdk_error) result) ->
  'a degraded_retry_prepare_result
(** Shared setup path for allowed degraded-runtime retries. The selector must
    provide a non-empty [next_runtime]; an empty target is converted into a
    setup failure instead of falling back to the current runtime. *)

val plan_degraded_retry_step :
  base_runtime:string ->
  current_runtime_id:string ->
  attempted_runtimes:string list ->
  estimated_input_tokens:int ->
  time_spent_in_turn_s:float option ->
  remaining_turn_budget_s:float ->
  attempt:int ->
  err:Agent_sdk.Error.sdk_error ->
  allow_retry:(EC.degraded_retry -> bool) ->
  publish_cascade_resolution:
    (runtime_id:string ->
     decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
     reason:string ->
     next_runtime:string option ->
     attempt:int ->
     Agent_sdk.Error.sdk_error ->
     unit) ->
  emit_runtime_selected:(runtime_id:string -> fallback_reason:string -> unit) ->
  emit_runtime_rotation:(from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
  setup_runtime:(string -> ('a, Agent_sdk.Error.sdk_error) result) ->
  'a degraded_retry_step
(** Shared degraded-runtime retry step for unified turns and direct
    no-progress turns. Callers supply their acceptance policy
    ([allow_retry]) and retain ownership of terminal-error handling. *)

val yield_before_direct_no_progress_retry : unit -> unit
(** Cooperative spacing used between direct no-progress retry attempts.
    No-progress accept rejection is a response-contract miss rather than a
    transport retry, so it intentionally yields without borrowing
    transient-network backoff. *)

val direct_no_progress_retry_reason :
  Agent_sdk.Error.sdk_error -> EC.degraded_retry_reason option
(** Return a direct-message no-progress retry reason for accept rejections that
    are safe to rotate before surfacing an error. *)

val direct_no_progress_retry_decision :
  base_runtime:string ->
  effective_runtime:string ->
  attempted_runtimes:string list ->
  estimated_input_tokens:int ->
  ?time_spent_in_turn_s:float ->
  remaining_turn_budget_s:float ->
  Agent_sdk.Error.sdk_error ->
  degraded_retry_budget_decision
(** Shared-budget retry decision for direct-message no-progress accept
    rejections. Read-only no-progress remains terminal here because it already
    consumed tool execution in the current attempt. *)

val run_direct_no_progress_retry_loop :
  keeper_name:string ->
  base_runtime:string ->
  initial_runtime:string ->
  initial_max_context:int ->
  estimated_input_tokens:int ->
  timeout_sec:float ->
  remaining_turn_budget_s:(unit -> float) ->
  current_turn_phase_elapsed_ms:(float option -> int * int option) ->
  now_s:(unit -> float) ->
  setup_retry_runtime:
    (string -> (runtime_execution, Agent_sdk.Error.sdk_error) result) ->
  publish_cascade_resolution:
    (runtime_id:string ->
     decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
     reason:string ->
     next_runtime:string option ->
     attempt:int ->
     Agent_sdk.Error.sdk_error ->
     unit) ->
  emit_runtime_selected:(runtime_id:string -> fallback_reason:string -> unit) ->
  emit_runtime_rotation:(from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
  record_retry_setup_failure:
    (from_runtime:string ->
     retry:EC.degraded_retry ->
     rotation_attempt:Keeper_execution_receipt.runtime_rotation_attempt ->
     fail_open_err:Agent_sdk.Error.sdk_error ->
     unit) ->
  before_retry:(unit -> unit) ->
  run_once:
    (runtime_id:string ->
     max_context:int ->
     is_retry:bool ->
     degraded_retry_runtime:string option ->
     fallback_reason:EC.degraded_retry_reason option ->
     runtime_rotation_attempts:
       Keeper_execution_receipt.runtime_rotation_attempt list ->
     ('a, Agent_sdk.Error.sdk_error) result) ->
  unit ->
  ('a * int, Agent_sdk.Error.sdk_error) result
(** Execute the direct-message no-progress retry loop with injected side
    effects. This keeps direct-message retry orchestration on the same budget
    and cascade path as unified degraded-runtime retries. *)

type turn_event_bus_overflow = {
  estimated_tokens : int;
  limit_tokens : int;
}

type turn_event_bus_compaction = {
  before_tokens : int;
  after_tokens : int;
  tokens_freed : int;
  phase_hint : string;
}

type turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
  overflow_imminent : turn_event_bus_overflow option;
  context_compact_started_count : int;
  context_compacted_count : int;
  last_compaction : turn_event_bus_compaction option;
}

val empty_turn_event_bus_summary : turn_event_bus_summary

val merge_turn_event_bus_summary :
  turn_event_bus_summary -> turn_event_bus_summary -> turn_event_bus_summary

val summarize_turn_event_bus :
  Agent_sdk.Event_bus.event list -> turn_event_bus_summary

val turn_event_bus_overflow_evidence_detail :
  turn_event_bus_summary -> string
(** Compact forensic string for preserving OAS compaction/retry event-bus
    evidence inside the keeper overflow blocker detail. *)

val context_overflow_event_of_error :
  fallback_tokens:int ->
  ?turn_event_bus:turn_event_bus_summary ->
  Agent_sdk.Error.sdk_error ->
  Keeper_state_machine.event

val pause_keeper_for_overflow :
  config:Workspace.config ->
  meta:keeper_meta ->
  reason:string ->
  keeper_meta
(** Pause a keeper after unresolved context overflow. Writes meta with merge-CAS
    using the [Turn_overflow_pause] failure-policy resume decision, records
    [Sdk_token_budget_exceeded] typed blocker metadata, latches
    [Turn_overflow_pause], and dispatches [Compact_retry_exhausted] then
    [Operator_pause]. Returns the paused meta. *)

val sync_keeper_paused_state :
  config:Workspace.config ->
  meta:keeper_meta ->
  paused:bool ->
  (keeper_meta, string) result
(** Persist paused/resumed state before mutating the live registry/phase.
    Returns [Error] when disk sync fails so callers can surface the failure
    instead of silently diverging runtime vs persisted state. *)

val sync_keeper_paused_state_with_resume_policy :
  config:Workspace.config ->
  meta:keeper_meta ->
  paused:bool ->
  resume_policy:Keeper_supervisor_pause_policy.crash_pause_resume_policy ->
  (keeper_meta, string) result
(** Like {!sync_keeper_paused_state}, but also applies [resume_policy] when
    pausing so automatic pause paths can enter the supervisor self-healing
    sweep instead of becoming an indefinite manual pause. *)

val current_keeper_meta :
  config:Workspace.config ->
  fallback_meta:keeper_meta ->
  keeper_meta
(** Read the latest meta from the registry, falling back to the given
    [fallback_meta] when the registry entry is missing. *)

type post_turn_resilience_handles = {
  resilience_audit_store : Shared_audit.Store.t option;
  resilience_strategy_executor : Resilience.Recovery.strategy_executor option;
  sync_lifecycle_meta :
    Keeper_context_runtime.post_turn_lifecycle ->
    Keeper_context_runtime.post_turn_lifecycle;
}
(** Runtime handles for the feature-flagged post-turn resilience wire-in.

    When [MASC_RESILIENCE] is off or the audit store cannot be opened, both
    handles are [None] and [sync_lifecycle_meta] is identity. When execution
    pauses a keeper for operator handoff/abort, [sync_lifecycle_meta] folds the
    persisted paused meta back into the lifecycle so the caller's normal final
    meta write does not accidentally unpause it. *)

val resilience_audit_dir :
  config:Workspace.config ->
  keeper_name:string ->
  string
(** Per-keeper audit root for resilience recovery envelopes. *)

val post_turn_resilience_handles :
  config:Workspace.config ->
  meta:keeper_meta ->
  post_turn_resilience_handles
(** Create per-turn resilience audit/executor handles. The audit store is
    per keeper to respect [Shared_audit.Store]'s single-writer chain
    contract. *)

val enqueue_partial_commit_continue_gate :
  config:Workspace.config ->
  meta:keeper_meta ->
  failure_reason:Keeper_registry.failure_reason ->
  committed_tools:string list ->
  error_detail:string ->
  string

val resolved_max_context_for_turn : meta:keeper_meta -> int
(** Resolve the initial keeper turn context budget from the keeper's routed
    runtime, so lifecycle context math matches the provider that will receive
    the first request. *)
