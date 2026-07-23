(** Keeper_unified_metrics_support — shared observation, trust, and JSON helpers for Keeper_unified_metrics. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

(* ── Observation / decision helpers ─────────────── *)

let decision_channel_of_observation
    (observation : Keeper_world_observation.world_observation) :
    Keeper_world_observation.keeper_cycle_channel =
  if observation.pending_messages <> []
     || observation.pending_board_events <> []
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
    ~(usage : Agent_sdk.Types.api_usage) : usage_trust =
  Keeper_usage_trust.classify ~usage_reported ~usage

(* #9953: bucket the raw [context_max] integer into a tightly
   bounded vocabulary so the Otel_metric_store label cardinality stays
   small AND the dashboards see the same drift the issue
   reported (42% / 17% / 41% three-way split for one model).

   Boundaries match observed deployments:
   - [zero]  : context_max = 0 (uninitialised / pre-resolve)
   - [64k]   : (0, 64_000]
   - [128k]  : (64_000, 128_000]
   - [200k]  : (128_000, 200_000]
   - [256k]  : (200_000, 262_144]
   - [1m]    : (262_144, 1_048_576]
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

(* #9943: per-keeper turn-latency bucket counter.  Buckets are
   chosen so each name a reachable operator state:

   - [under_60s]:    routine turn; no signal.
   - [60-300s]:      acceptable for cloud-LLM heavy turns.
   - [300-600s]:     unusually slow; investigate if persistent.
   - [600-1200s]:    long turn — approaches but does not exceed
                     the keeper turn deadline. Operator-actionable
                     latency warning.
   - [over_1200s]:   turn longer than the keeper turn deadline.
                     Inspect owner-specific runtime evidence
                     (provider timeout, admission/capacity, or
                     turn liveness) before classifying the cause.

   Boundaries are inclusive on the upper edge so 60.0 → 60-300,
   600.0 → 600-1200, 1200.0 → over_1200s.  This matches the
   typical "alert on turn > 600s" threshold operators use. *)
let turn_latency_bucket (latency_ms : int) : string =
  let s = float_of_int latency_ms /. 1000.0 in
  if s < 60.0 then "under_60s"
  else if s < 300.0 then "60-300s"
  else if s < 600.0 then "300-600s"
  else if s < 1200.0 then "600-1200s"
  else "over_1200s"

(* Default WARN threshold (10 minutes).  Picks up the 600-1200s
   and over_1200s buckets without firing on routine cloud-LLM
   turns. Env-overridable. *)
let long_turn_warn_threshold_ms_default = 600_000

let long_turn_warn_threshold_ms () : int =
  Env_config_core.get_int
    ~default:long_turn_warn_threshold_ms_default
    "MASC_KEEPER_LONG_TURN_WARN_MS"

let record_turn_latency_bucket
    ~(keeper : string)
    ~(latency_ms : int) : unit =
  let bucket = turn_latency_bucket latency_ms in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnLatencyBucket)
    ~labels:[ ("keeper", keeper); ("bucket", bucket) ]
    ();
  let threshold = long_turn_warn_threshold_ms () in
  if latency_ms >= threshold then
    Log.Keeper.warn
      "[long-turn] keeper=%s latency_ms=%d (>= %d ms threshold) bucket=%s \
       — inspect owner-specific runtime evidence before classifying timeout cause"
      keeper latency_ms threshold bucket

let label_or_unknown raw =
  let trimmed = String.trim raw in
  if trimmed = "" then "unknown" else trimmed

let record_turn_latency_by_model_bucket
    ~(keeper : string)
    ~(channel : string)
    ~(runtime_profile : string)
    ~(latency_ms : int) : unit =
  let bucket = turn_latency_bucket latency_ms in
  let model_used = runtime_lane_label in
  let resolved_model_id = runtime_lane_label in
  let provider_kind =
    Boundary_redaction.to_string Boundary_redaction.runtime_provider_label
  in
  let runtime_profile = label_or_unknown runtime_profile in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string TurnLatencyByModelBucket)
    ~labels:
      [ ("keeper", label_or_unknown keeper)
      ; ("channel", label_or_unknown channel)
      ; ("provider_kind", provider_kind)
      ; ("model_used", model_used)
      ; ("resolved_model_id", resolved_model_id)
      ; ("runtime_profile", runtime_profile)
      ; ("bucket", bucket)
      ]
    ()


(* cost_usd is the provider's authoritative observation. Preserve every
   reported value verbatim, including zero and invalid negative values, so the
   anomaly remains diagnosable instead of being silently rewritten. Missing is
   represented by the existing 0.0 aggregate identity. *)
let estimate_usage_cost_usd usage =
  match usage.Agent_sdk.Types.cost_usd with
  | Some cost -> cost
  | None -> 0.0

let usage_trust_to_string = Keeper_usage_trust.to_string

let usage_trust_reasons = Keeper_usage_trust.reasons

let usage_trust_json_fields = Keeper_usage_trust.json_fields

(* #9959 defensive observability: surface usage-field trust into
   Otel_metric_store so operators can alert on rising untrusted/missing
   rates while the upstream OAS fix (jeong-sik/oas#1181 —
   accumulated values leaking into per-response [api_usage]) lands.

   Two counters:
   - [masc_keeper_usage_trust_total{keeper, outcome}] — high-level
     outcome (trusted / missing / untrusted).
   - [masc_keeper_usage_anomaly_reason_total{keeper, reason}] —
     per-reason drill-down for objectively invalid negative counters.

   Called once per turn from [update_metrics_from_result]; other
   classify sites (append_metrics_snapshot, keeper_turn) serialize
   the trust into the JSONL ledger but do not bump the counter, so
   the counter rate equals the per-turn rate rather than 2–3×. *)
let usage_trust_outcome_metric = Keeper_metrics.(to_string UsageTrust)
let usage_anomaly_reason_metric = Keeper_metrics.(to_string UsageAnomalyReason)

let keeper_total_cost_usd_help =
  "Accumulated provider-reported USD cost per keeper (labels: keeper_name)"

let record_usage_trust ~keeper_name ~(trust : usage_trust) =
  let outcome = usage_trust_to_string trust in
  Otel_metric_store.inc_counter usage_trust_outcome_metric
    ~labels:[ ("keeper", keeper_name); ("outcome", outcome) ] ();
  match trust with
  | Usage_untrusted reasons ->
    List.iter
      (fun reason ->
        Otel_metric_store.inc_counter usage_anomaly_reason_metric
          ~labels:[ ("keeper", keeper_name); ("reason", reason) ] ())
      reasons;
    let warns_operator = Keeper_usage_trust.warns_operator trust in
    let log_usage =
      if warns_operator then Log.Keeper.warn else Log.Keeper.info
    in
    log_usage
      "usage anomaly keeper=%s reasons=[%s] severity=%s; raw token and cost \
       observations remain recorded"
      keeper_name
      (String.concat "," reasons)
      (if warns_operator then "warn" else "info")
  | Usage_missing | Usage_trusted -> ()

let record_keeper_total_cost_usd ~keeper_name ~total_cost_usd =
  let labels = [ ("keeper", keeper_name) ] in
  Otel_metric_store.register_gauge
    ~name:Keeper_metrics.(to_string TotalCostUsd)
    ~help:keeper_total_cost_usd_help
    ~labels
    ();
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string TotalCostUsd)
    ~labels
    total_cost_usd

let record_keeper_idle_seconds ~keeper_name ~idle_seconds =
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string IdleSeconds)
    ~labels:[ ("keeper", keeper_name) ]
    (float_of_int (max 0 idle_seconds))

(* RFC-0182 §3.1 cycle break — codecs live in [Turn_mode_codec]. *)
let turn_mode_to_string = Turn_mode_codec.turn_mode_to_string
let turn_mode_of_string = Turn_mode_codec.turn_mode_of_string
let work_kind_of_turn_mode = Turn_mode_codec.work_kind_of_turn_mode

let has_substantive_tool_calls (tools_used : string list) : bool =
  tools_used <> []

(** A cycle is empty only when it emitted neither text nor a tool call. Tool
    meaning is not inferred from its name. *)
let is_noop_cycle ~has_text ~(tools_used : string list) : bool =
  (not has_text) && tools_used = []

let visible_run_validation (result : Keeper_agent_run.run_result) :
    Agent_sdk.Raw_trace.run_validation option =
  match result.run_validation with
  | Some v when v.ok && v.evidence <> [] -> Some v
  | _ -> None

let telemetry_reported_of_result
    (result : Keeper_agent_run.run_result) : bool =
  Option.is_some result.inference_telemetry

let coverage_reason_of_result
    (result : Keeper_agent_run.run_result) : string option =
  let telemetry_reported = telemetry_reported_of_result result in
  if result.usage_reported && telemetry_reported then None
  else
    match result.usage_reported, telemetry_reported with
    | false, false -> Some "missing_usage_and_inference"
    | false, true -> Some "missing_usage"
    | true, false -> Some "missing_inference"
    | true, true -> None

let coverage_stage_of_result
    (result : Keeper_agent_run.run_result) : string option =
  if result.usage_reported && telemetry_reported_of_result result
  then None
  else Some "oas"

let coverage_stage_of_no_result_outcome = function
  | "skipped" | "cancelled" -> "pre_dispatch"
  | _ -> "unknown"

let coverage_reason_of_no_result_outcome = function
  | "skipped" -> "skipped_turn"
  | "cancelled" -> "cancelled_turn"
  | "partial" -> "partial_turn"
  | "error" -> "error_turn"
  | _ -> "no_run_result"

let has_visible_tool_signal (result : Keeper_agent_run.run_result) : bool =
  has_substantive_tool_calls (Keeper_agent_result.tool_names result)
  || Option.is_some (visible_run_validation result)

let validated_evidence_preview
    (v : Agent_sdk.Raw_trace.run_validation) : string =
  match v.tool_names with
  | [] -> "(validated evidence)"
  | names ->
    Printf.sprintf "(validated evidence: %s)" (String.concat ", " names)

(* RFC-0232: the scheduled-autonomous "what is this keeper doing" preview, by
   precedence. [is_visible_reply] is the typed reply-surface outcome
   ([Keeper_turn_outcome.of_result_surface]) — an OAS turn-limit observation
   may have no visible reply text, and a
   completed runtime turn may still have no visible reply. Neither case may be
   sniffed as model output, so visible model text only wins when the outcome is
   [Visible_reply]. Then substantive tool calls, then validated evidence, else
   the prior preview is kept (never overwritten with a synthetic filler). Pure
   so the precedence is unit-testable without a keeper_meta. *)
let select_proactive_preview
    ~(previous : string)
    ~(has_text : bool)
    ~(is_visible_reply : bool)
    ~(has_substantive_tools : bool)
    ~(tool_names : string list)
    ~(response_text : string)
    ~(validated_evidence_preview : string option)
  : string =
  if has_text && is_visible_reply then short_preview response_text
  else if has_substantive_tools then
    Printf.sprintf "(tools: %s)" (String.concat ", " tool_names)
  else match validated_evidence_preview with
    | Some preview -> preview
    | None -> previous

let accountability_evidence_refs
    ~(trace_id : string)
    ~(turn_number : int)
    ~(result : Keeper_agent_run.run_result)
    ~(validated_evidence : Agent_sdk.Raw_trace.run_validation option) =
  let tool_refs =
    Keeper_agent_result.tool_names result
    |> List.filter_map (fun tool_name ->
           let trimmed = String.trim tool_name in
           if trimmed = "" then None
           else Some ("tool:" ^ trimmed))
  in
  let validation_refs =
    match validated_evidence with
    | Some validation ->
      validation.evidence
      |> List.map String.trim
      |> List.filter (fun entry -> entry <> "")
      |> List.map (fun entry -> "validation:" ^ entry)
    | None -> []
  in
  let turn_refs = [ Printf.sprintf "turn:%s:%d" trace_id turn_number ] in
  tool_refs @ validation_refs @ turn_refs

let scheduled_autonomous_outcome_for_result
    (result : Keeper_agent_run.run_result) :
    proactive_cycle_outcome =
  scheduled_autonomous_outcome_of_result
    ~has_text:(String.trim result.response_text <> "")
    ~has_tool_calls:(has_visible_tool_signal result)

let turn_mode_of_result (result : Keeper_agent_run.run_result) : turn_mode =
  let text = String.trim result.response_text in
  if has_visible_tool_signal result then Tool_use
  else if text = "" then Noop
  else if String.starts_with ~prefix:"SKIP:" text then Skip_text
  else Text_response

let turn_mode_of_json = Turn_mode_codec.turn_mode_of_json
let work_kind_of_json = Turn_mode_codec.work_kind_of_json

let claim_backlog_actionable
    (observation : Keeper_world_observation.world_observation) : bool =
  observation.claimable_task_count > 0

let singleton_when condition label =
  if condition then [ label ] else []

let observed_triggers_of_observation
    ?meta
    (observation : Keeper_world_observation.world_observation) : string list =
  let _ = meta in
  let actionable_backlog = claim_backlog_actionable observation in
  List.concat
    [
      singleton_when
        (Keeper_world_observation_message_scope.has_kind
           Keeper_world_observation_message_scope.Mention observation.pending_messages)
        "direct_mention";
      singleton_when (observation.pending_board_events <> []) "board_activity";
      singleton_when
        (Keeper_world_observation_message_scope.has_kind
           Keeper_world_observation_message_scope.Scope observation.pending_messages)
        "scope_message";
      singleton_when actionable_backlog "new_unclaimed_task";
      singleton_when actionable_backlog "claimable_task";
      singleton_when (observation.failed_task_count > 0) "failed_task";
      singleton_when
        (observation.pending_verification_count > 0)
        "pending_verification";
      singleton_when
        (observation.scheduled_automation.due_ready_count > 0)
        "scheduled_automation_due_ready";
      singleton_when
        (observation.active_goals <> [] && observation.idle_seconds > 0)
        "idle_timeout_candidate";
    ]

let observed_affordances_of_observation
    ?meta
    (observation : Keeper_world_observation.world_observation) : string list =
  let affordances = ref [] in
  let add affordance = affordances := affordance :: !affordances in
  if observation.pending_board_events <> []
  then (
    add "board_post_or_comment";
    add "board_curation");
  let _ = meta in
  if Keeper_world_observation_message_scope.has_kind
       Keeper_world_observation_message_scope.Scope observation.pending_messages
  then add "message_sweep";
  if claim_backlog_actionable observation then add "task_claim";
  if observation.failed_task_count > 0 then add "task_audit";
  if observation.pending_verification_count > 0 then
    add "task_verify";
  if observation.scheduled_automation.due_ready_count > 0 then
    add "schedule_dispatch_monitor";
  List.rev !affordances
