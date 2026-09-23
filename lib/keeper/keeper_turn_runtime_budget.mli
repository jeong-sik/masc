(* Keeper_turn_runtime_budget — runtime execution types,
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

(** The candidates a turn's walk may dispatch, as the walk itself reads them.
    - [Lane_of_route route]: a fresh walk over every candidate of the lane
      [route] names, or the runtime itself when it names one.
    - [Deferred_candidates ids]: a deferred lane suffix, dispatched exactly as
      listed. *)
type briefing_candidates =
  | Lane_of_route of string
  | Deferred_candidates of string list

val world_state_briefing_budget_bytes : briefing_candidates -> int option
(** Byte budget for the pinned world-state briefing:
    [keeper.context.briefing.share_percent] of the smallest [max-prompt-bytes]
    those candidates declare, so the briefing fits whichever of them serves
    the turn. A candidate that declares none adds no ceiling. [None] when no
    candidate declares a ceiling, or the route names nothing. *)

val resolved_max_context_for_turn
  :  meta:keeper_meta
  -> Keeper_context_runtime.max_context_resolution
  -> int
(** Resolve the initial keeper turn context budget from the keeper's routed
    runtime's prevalidated resolution, so lifecycle context math matches the
    provider that will receive the first request. *)
