(** Keeper_unified_metrics_types — shared types, string utilities,
    trust classification, and context bucket helpers extracted from
    [Keeper_unified_metrics_support] (583 LoC).  Observation/metrics
    recording functions remain in the parent.
    @since Keeper 500-line decomposition *)

(** Keeper_unified_metrics_support — shared observation, trust, and JSON helpers for Keeper_unified_metrics. *)

open Keeper_types
open Keeper_exec_context
module Social = Keeper_social_model

(* ── String utilities (private, duplicated from keeper_unified_turn
      to avoid circular module dependency) ────────── *)

let substring_matches_at ~(needle : string) (haystack : string) start_idx =
  let needle_len = String.length needle in
  let rec loop offset =
    if offset = needle_len then true
    else if haystack.[start_idx + offset] <> needle.[offset] then false
    else loop (offset + 1)
  in
  loop 0

let string_contains_substring ~(needle : string) (haystack : string) : bool =
  let needle_len = String.length needle in
  let hay_len = String.length haystack in
  if needle_len = 0 then true
  else if needle_len > hay_len then false
  else
    let rec loop i =
      if i + needle_len > hay_len then false
      else if substring_matches_at ~needle haystack i then true
      else loop (i + 1)
    in
    loop 0

let string_contains_substring_ci ~(needle : string) (haystack : string) : bool =
  string_contains_substring
      ~needle:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)


(* ── Observation / decision helpers ─────────────── *)

let decision_channel_of_observation
    (observation : Keeper_world_observation.world_observation) : string =
  if observation.pending_mentions <> []
     || observation.pending_board_events <> []
     || observation.pending_scope_messages <> []
  then
    "turn"
  else
    "scheduled_autonomous"

let is_scheduled_autonomous_channel =
  Keeper_world_observation.is_autonomous_channel

let is_scheduled_autonomous_cycle_of_observation
    (observation : Keeper_world_observation.world_observation) : bool =
  String.equal
    (decision_channel_of_observation observation)
    "scheduled_autonomous"

let scheduled_autonomous_outcome_of_result
    ~(has_text : bool) ~(has_tool_calls : bool) :
    proactive_cycle_outcome =
  match has_text, has_tool_calls with
  | false, false -> Proactive_silent
  | true, false -> Proactive_text_response
  | false, true -> Proactive_tool_use
  | true, true -> Proactive_mixed_response

type turn_mode =
  | Tool_use
  | Text_response
  | Skip_text
  | Noop

type usage_trust = Keeper_usage_trust.t =
  | Usage_missing
  | Usage_trusted
  | Usage_untrusted of string list

(* RFC-0132 PR-2: Prometheus metric label = external boundary; redact via SSOT. *)
let runtime_lane_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label

let classify_usage_trust ~(usage_reported : bool)
    ~(usage : Agent_sdk.Types.api_usage)
    ~(context_max : int) : usage_trust =
  Keeper_usage_trust.classify ~usage_reported ~usage ~context_max

(* #9953: bucket the raw [context_max] integer into a tightly
   bounded vocabulary so the Prometheus label cardinality stays
   small AND the dashboards see the same drift the issue
   reported (42% / 17% / 41% three-way split for one model).

   Boundaries match observed deployments:
   - [zero]  : context_max = 0 (uninitialised / pre-resolve)
   - [64k]   : (0, 64_000]
   - [128k]  : (64_000, 128_000]
   - [200k]  : (128_000, 200_000]   — provider_a model-a-sonnet
   - [256k]  : (200_000, 262_144]   — provider_c / agent_llm_a haiku 4.5
   - [1m]    : (262_144, 1_048_576] — agent_llm_a opus 4.7 / 1M
   - [other] : everything else (sanity check / future caps) *)
let context_max_bucket (n : int) : string =
  if n <= 0 then "zero"
  else if n <= 64_000 then "64k"
  else if n <= 128_000 then "128k"
  else if n <= 200_000 then "200k"
  else if n <= 262_144 then "256k"
  else if n <= 1_048_576 then "1m"
  else "other"
