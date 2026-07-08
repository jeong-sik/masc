(** Keeper_unified_metrics_support — shared observation, trust, and JSON helpers for Keeper_unified_metrics. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

let string_contains_substring = String_util.string_contains_substring

let string_contains_substring_ci = String_util.string_contains_substring_ci


(* ── Observation / decision helpers ─────────────── *)

let decision_channel_of_observation
    (observation : Keeper_world_observation.world_observation) :
    Keeper_world_observation.keeper_cycle_channel =
  if observation.pending_mentions <> []
     || observation.pending_board_events <> []
     || observation.pending_scope_messages <> []
  then
    Keeper_world_observation.Reactive
  else
    Keeper_world_observation.Scheduled_autonomous

let is_scheduled_autonomous_cycle_of_observation
    (observation : Keeper_world_observation.world_observation) : bool =
  Keeper_world_observation.is_autonomous
    (decision_channel_of_observation observation)

let scheduled_autonomous_outcome_of_result
    ~(has_text : bool) ~(has_tool_calls : bool) :
    proactive_cycle_outcome =
  match has_text, has_tool_calls with
  | false, false -> Proactive_silent
  | true, false -> Proactive_text_response
  | false, true -> Proactive_tool_use
  | true, true -> Proactive_mixed_response

(* RFC-0182 §3.1 cycle break (2026-05-27) — [turn_mode] and its
   codec functions were extracted to [Turn_mode_codec] in lib/ so
   [Tool_agent_timeline] can parse keeper turn payloads without
   importing this module (which would form a Config-mediated dependency
   cycle with [Keeper_tool_in_process_runtime]). The local re-export
   keeps existing callers source-compatible. *)
type turn_mode = Turn_mode_codec.turn_mode =
  | Tool_use
  | Text_response
  | Skip_text
  | Noop

type usage_trust = Keeper_usage_trust.t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

(* RFC-0132 PR-2: Otel_metric_store metric label = external boundary; redact via SSOT. *)
let runtime_lane_label = Boundary_redaction.to_string Boundary_redaction.runtime_lane_label

let classify_usage_trust ~(usage_reported : bool)
    ~(usage : Agent_sdk.Types.api_usage)
    ~(context_max : int) : usage_trust =
  Keeper_usage_trust.classify ~usage_reported ~usage ~context_max

(* #9953: bucket the raw [context_max] integer into a tightly
   bounded vocabulary so the Otel_metric_store label cardinality stays