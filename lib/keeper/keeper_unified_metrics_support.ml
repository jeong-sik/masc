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
small AND the dashboards see the same drift the issue
reported (42% / 17% / 41% three-way split for one model).
Boundaries match observed deployments:
- [zero] : context_max = 0 (uninitialised / pre-resolve)
- [64k] : (0, 64_000]
- [128k] : (64_000, 128_000]
- [200k] : (128_000, 200_000]
- [256k] : (200_000, 262_144]
- [1m] : (262_144, 1_048_576]
- [other] : everything else (sanity check / future caps) *)
let context_max_bucket (n : int) : string =
if n <= 0 then "zero"
else if n <= 64_000 then "64k"
else if n <= 128_000 then "128k"
else if n <= 200_000 then "200k"
else if n <= 262_144 then "256k"
else if n <= 1_048_576 then "1m"
else "other"

let record_context_max_observation
    ~(keeper : string)
    ~(context_max : int) : unit =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ContextMaxObserved)
    ~labels:
    [
      ("keeper", keeper);
      ("model_used", runtime_lane_label);
      ("resolved_model_id", runtime_lane_label);
      ("context_max_bucket", context_max_bucket context_max);
    ]
  ()

(* #9943: per-keeper turn-latency bucket counter. Buckets are
chosen so each name a reachable operator state:
- [under_60s]: routine turn; no signal.
- [under_5m]: slow turn; tool-helal threshold hit.
- [under_15m]: very slow turn; potential regression or stall.
- [over_15m]: stalled turn; almost certainly a bug.
- [other]: sanity check / future caps. *)
let turn_latency_bucket (duration_sec : int) : string =
if duration_sec < 0 then "other"
else if duration_sec < 60 then "under_60s"
else if duration_sec < 300 then "under_5m"
else if duration_sec < 900 then "under_15m"
else if duration_sec < 3600 then "over_15m"
else "other"

let record_turn_latency_observation
    ~(keeper : string)
    ~(duration_sec : int) : unit =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnLatencyObserved)
    ~labels:
    [
      ("keeper", keeper);
      ("model_used", runtime_lane_label);
      ("resolved_model_id", runtime_lane_label);
      ("turn_latency_bucket", turn_latency_bucket duration_sec);
    ]
  ()

(* #9944: per-keeper tool-call counter. The buckets are the same as turn-latency. *)
let record_tool_call_count_observation
    ~(keeper : string)
    ~(tool_call_count : int) : unit =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ToolCallCountObserved)
    ~labels:
    [
      ("keeper", keeper);
      ("model_used", runtime_lane_label);
      ("resolved_model_id", runtime_lane_label);
      ("tool_call_count_bucket", turn_latency_bucket tool_call_count);
    ]
  ()

(* #9945: per-keeper tool-call ratio (failed / total). The buckets are the same as turn-latency. *)
let record_tool_fail_ratio_observation
    ~(keeper : string)
    ~(failed_count : int)
    ~(total_count : int) : unit =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ToolFailRatioObserved)
    ~labels:
    [
      ("keeper", keeper);
      ("model_used", runtime_lane_label);
      ("resolved_model_id", runtime_lane_label);
      ("tool_call_count_bucket", turn_latency_bucket failed_count);
    ]
  ()

(* #9946: per-keeper tool-call ratio (failed / total) — denominator bucket. *)
let record_tool_fail_ratio_denom_bucket
    ~(total_count : int) : string =
  if total_count <= 0 then "zero"
  else if total_count <= 10 then "low"
  else if total_count <= 100 then "medium"
  else "high"

(* ── Metric recording ── *)

let record_cycle_count_observation
    ~(cycle_count : int) : unit =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string CycleCountObserved)
    ~labels:
    [
      ("cycle_count_bucket", turn_latency_bucket cycle_count);
    ]
  ()

(* ── Response truncation helpers ── *)

let short_preview (response_text : string) : string =
  if String.length response_text <= 200 then
    response_text
  else
    String.sub response_text 0 200 ^ "..."

let is_visible_reply = Keeper_context_runtime.is_visible_reply

(* Return the shortest visible text response that is not an OAS loop.
* The function first checks if the response is visible and has text.
* If so, it returns the short preview. Otherwise, it returns the full
  response text.
* This prevents the OAS loop where the keeper keeps seeing
  the same text and re-generating the same response. *)
let visible_text_feedback
    >(response_text : string)
    >(short_preview : string -> string)
    >(is_visible_reply : bool)
    > response_text : string =
  if has_text && is_visible_reply then short_preview response_text
  else response_text