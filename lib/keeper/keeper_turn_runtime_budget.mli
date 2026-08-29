(* Keeper_turn_runtime_budget — runtime execution types, fail-open rotation,
   context overflow observation, Keeper lifecycle
   sync, and context budget resolution.

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
}

val next_fail_open_runtime_for_turn :
  base_runtime:string ->
  effective_runtime:string ->
  attempted_runtimes:string list ->
  Agent_core.Error.t ->
  EC.degraded_retry option
(** Same-turn retries use the generic keeper-assignable rotation catalog plus
    any explicit [fallback_runtime] hint. *)

type degraded_retry_decision =
  | No_degraded_retry
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
      fail_open_err : Agent_core.Error.t;
    }

type 'a degraded_retry_step =
  | Degraded_retry_step_not_allowed
  | Degraded_retry_step_setup_failed of {
      retry : EC.degraded_retry;
      reason : string;
      fail_open_err : Agent_core.Error.t;
    }
  | Degraded_retry_step_prepared of {
      retry : EC.degraded_retry;
      reason : string;
      next : 'a;
    }

val decide_degraded_retry :
  base_runtime:string ->
  effective_runtime:string ->
  attempted_runtimes:string list ->
  Agent_core.Error.t ->
  degraded_retry_decision

val prepare_degraded_retry_allowed :
  current_runtime_id:string ->
  attempt:int ->
  err:Agent_core.Error.t ->
  retry:EC.degraded_retry ->
  publish_cascade_resolution:
    (runtime_id:string ->
     decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
     reason:string ->
     next_runtime:string option ->
     attempt:int ->
     Agent_core.Error.t ->
     unit) ->
  emit_runtime_selected:(runtime_id:string -> fallback_reason:string -> unit) ->
  emit_runtime_rotation:(from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
  setup_runtime:(string -> ('a, Agent_core.Error.t) result) ->
  'a degraded_retry_prepare_result
(** Shared setup path for allowed degraded-runtime retries. The selector must
    provide a non-empty [next_runtime]; an empty target is converted into a
    setup failure instead of falling back to the current runtime. *)

val plan_degraded_retry_step :
  base_runtime:string ->
  current_runtime_id:string ->
  attempted_runtimes:string list ->
  attempt:int ->
  err:Agent_core.Error.t ->
  allow_retry:(EC.degraded_retry -> bool) ->
  publish_cascade_resolution:
    (runtime_id:string ->
     decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
     reason:string ->
     next_runtime:string option ->
     attempt:int ->
     Agent_core.Error.t ->
     unit) ->
  emit_runtime_selected:(runtime_id:string -> fallback_reason:string -> unit) ->
  emit_runtime_rotation:(from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
  setup_runtime:(string -> ('a, Agent_core.Error.t) result) ->
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
  Agent_core.Error.t -> EC.degraded_retry_reason option
(** Return a direct-message no-progress retry reason for accept rejections that
    are safe to rotate before surfacing an error. *)

val direct_no_progress_retry_decision :
  base_runtime:string ->
  effective_runtime:string ->
  attempted_runtimes:string list ->
  Agent_core.Error.t ->
  degraded_retry_decision
(** Retry decision for direct-message no-progress accept rejections. Read-only
    no-progress remains terminal here because it already consumed tool
    execution in the current attempt. *)

val run_direct_no_progress_retry_loop :
  keeper_name:string ->
  base_runtime:string ->
  initial_execution:runtime_execution ->
  current_turn_phase_elapsed_ms:(float option -> int * int option) ->
  now_s:(unit -> float) ->
  setup_retry_runtime:
    (string -> (runtime_execution, Agent_core.Error.t) result) ->
  publish_cascade_resolution:
    (runtime_id:string ->
     decision:Keeper_unified_turn_cascade_resolution.cascade_decision_kind ->
     reason:string ->
     next_runtime:string option ->
     attempt:int ->
     Agent_core.Error.t ->
     unit) ->
  emit_runtime_selected:(runtime_id:string -> fallback_reason:string -> unit) ->
  emit_runtime_rotation:(from_runtime:string -> to_runtime:string -> reason:string -> unit) ->
  record_retry_setup_failure:
    (from_runtime:string ->
     retry:EC.degraded_retry ->
     rotation_attempt:Keeper_execution_receipt.runtime_rotation_attempt ->
     fail_open_err:Agent_core.Error.t ->
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
     ('a, Agent_core.Error.t) result) ->
  unit ->
  ('a * int, Agent_core.Error.t) result
(** Execute the direct-message no-progress retry loop with injected side
    effects. The initial provider attempt receives the same typed runtime
    execution record as every retry, so its context budget cannot diverge from
    pre-dispatch resolution. Rotation is bounded only by the typed, finite
    runtime candidate set; no numeric Keeper budget participates in admission
    or retry. *)

type turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
}

val empty_turn_event_bus_summary : turn_event_bus_summary

val merge_turn_event_bus_summary :
  turn_event_bus_summary -> turn_event_bus_summary -> turn_event_bus_summary

val summarize_turn_event_bus :
  Agent_core.Event_bus.event list -> turn_event_bus_summary

val turn_event_bus_evidence_detail :
  turn_event_bus_summary -> string
(** Compact forensic string for observed AGENT_CORE events around a typed provider
    failure. *)

type capacity_refusal =
  | Provider_context_window of { limit_tokens : int option }
  | Serialized_request_body of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Provider_request_body_refusal of { status : int }
(** Why a target refused to serve a request for its size. The closed set keeps
    measured token and byte bounds separate from a provider refusal whose only
    typed evidence is an HTTP status. Missing measurements are never invented. *)

val capacity_refusal_of_error :
  Agent_core.Error.t ->
  capacity_refusal option
(** Total classifier over typed agent-core errors onto the token/byte refusal
    axes. This function does not inspect rendered error prose and does not
    select a provider, model, or failover. *)

val current_keeper_meta :
  config:Workspace.config ->
  fallback_meta:keeper_meta ->
  keeper_meta
(** Read the latest meta from the registry, falling back to the given
    [fallback_meta] when the registry entry is missing. *)

val resolved_max_context_for_turn
  :  meta:keeper_meta
  -> Keeper_context_runtime.max_context_resolution
  -> int
(** Resolve the initial keeper turn context budget from the keeper's routed
    runtime's prevalidated resolution, so lifecycle context math matches the
    provider that will receive the first request. *)
