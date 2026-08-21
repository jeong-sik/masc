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
(** Project the canonical capacity transition onto the token/byte refusal axes. *)

type capacity_non_compaction =
  | Serving_evidence_not_yet_valid of
      { now_unix_s : int
      ; checked_at_unix_s : int
      }
  | Serving_evidence_expired of
      { now_unix_s : int
      ; expires_at_unix_s : int
      }
  | Token_measurement_unavailable

type capacity_transition =
  | Not_capacity
  | Capacity_refusal_classified of Compaction_trigger.t
  | Capacity_non_compacting of capacity_non_compaction
(** Provider-neutral transition input for the durable compaction lane.
    [Capacity_refusal_classified] preserves the measured token or byte axis.
    Future/expired serving evidence and unavailable token measurement remain
    typed non-compacting facts; they are never guessed into a capacity limit. *)

val capacity_transition_of_error :
  Agent_core.Error.t ->
  capacity_transition
(** Total classifier over typed agent-core errors. This function does not inspect
    rendered error prose and does not select a provider, model, or failover. *)

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
