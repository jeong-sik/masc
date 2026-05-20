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
    scheduled_autonomous_cycle_outcome =
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
    ~(model_used : string)
    ~(resolved_model_id : string)
    ~(context_max : int) : usage_trust =
  let _ = model_used, resolved_model_id in
  Keeper_usage_trust.classify ~usage_reported ~usage
    ~model_used:runtime_lane_label
    ~resolved_model_id:runtime_lane_label
    ~context_max

(* #9953: bucket the raw [context_max] integer into a tightly
   bounded vocabulary so the Prometheus label cardinality stays
   small AND the dashboards see the same drift the issue
   reported (42% / 17% / 41% three-way split for one model).

   Boundaries match observed deployments:
   - [zero]  : context_max = 0 (uninitialised / pre-resolve)
   - [64k]   : (0, 64_000]
   - [128k]  : (64_000, 128_000]
   - [200k]  : (128_000, 200_000]   — anthropic claude-sonnet-4
   - [256k]  : (200_000, 262_144]   — kimi / claude haiku 4.5
   - [1m]    : (262_144, 1_048_576] — claude opus 4.7 / 1M
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
    ~(model_used : string)
    ~(resolved_model_id : string)
    ~(context_max : int) : unit =
  let _ = model_used, resolved_model_id in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_context_max_observed
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
                     the 1200s [oas_timeout_budget] cap (#9933).
                     Operator-actionable warning.
   - [over_1200s]:   turn longer than the OAS budget cap.
                     Almost always indicates the budget fired
                     and the keeper retried.  Direct evidence
                     of #9943's 1,204,542 ms taskmaster sample.

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
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_turn_latency_bucket
    ~labels:[ ("keeper", keeper); ("bucket", bucket) ]
    ();
  let threshold = long_turn_warn_threshold_ms () in
  if latency_ms >= threshold then
    Log.Keeper.warn
      "[long-turn] keeper=%s latency_ms=%d (>= %d ms threshold) bucket=%s \
       — investigate cascade exhaustion / oas_timeout_budget (#9933, #9943)"
      keeper latency_ms threshold bucket

let label_or_unknown raw =
  let trimmed = String.trim raw in
  if trimmed = "" then "unknown" else trimmed

let provider_kind_of_model_used raw =
  (* RFC-0132 PR-2: provider kind label = external boundary; redact via SSOT. *)
  let _ = raw in
  Boundary_redaction.to_string Boundary_redaction.runtime_provider_label

let record_turn_latency_by_model_bucket
    ~(keeper : string)
    ~(channel : string)
    ~(model_used : string)
    ~(resolved_model_id : string)
    ~(cascade_profile : string)
    ~(latency_ms : int) : unit =
  let bucket = turn_latency_bucket latency_ms in
  let _ = model_used, resolved_model_id in
  let model_used = runtime_lane_label in
  let resolved_model_id = runtime_lane_label in
  let cascade_profile = label_or_unknown cascade_profile in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_turn_latency_by_model_bucket
    ~labels:
      [ ("keeper", label_or_unknown keeper)
      ; ("channel", label_or_unknown channel)
      ; ("provider_kind", provider_kind_of_model_used model_used)
      ; ("model_used", model_used)
      ; ("resolved_model_id", resolved_model_id)
      ; ("cascade_profile", cascade_profile)
      ; ("bucket", bucket)
      ]
    ()


let usage_trust_is_trusted = Keeper_usage_trust.is_trusted

let estimate_trusted_usage_cost_usd ~usage_trusted ~model:_ usage =
  if usage_trusted then
    match usage.Agent_sdk.Types.cost_usd with
    | Some cost when cost > 0.0 -> cost
    | Some _ | None -> 0.0
  else 0.0

let usage_trust_to_string = Keeper_usage_trust.to_string

let usage_trust_reasons = Keeper_usage_trust.reasons

let usage_trust_json_fields = Keeper_usage_trust.json_fields

(* #9959 defensive observability: surface usage-field trust into
   Prometheus so operators can alert on rising untrusted/missing
   rates while the upstream OAS fix (jeong-sik/oas#1181 —
   accumulated values leaking into per-response [api_usage]) lands.

   Two counters:
   - [masc_keeper_usage_trust_total{keeper, outcome}] — high-level
     outcome (trusted / missing / untrusted).
   - [masc_keeper_usage_anomaly_reason_total{keeper, reason}] —
     per-reason drill-down for untrusted outcomes (e.g.
     [input_tokens_gt_1m], [input_tokens_gt_2x_context_max],
     [zero_token_usage_reported]).

   Called once per turn from [update_metrics_from_result]; other
   classify sites (append_metrics_snapshot, keeper_turn) serialize
   the trust into the JSONL ledger but do not bump the counter, so
   the counter rate equals the per-turn rate rather than 2–3×. *)
let usage_trust_outcome_metric = Keeper_metrics.metric_keeper_usage_trust
let usage_anomaly_reason_metric = Keeper_metrics.metric_keeper_usage_anomaly_reason

let keeper_total_cost_usd_help =
  "Accumulated trusted USD cost per keeper (labels: keeper_name)"

let record_usage_trust ~keeper_name ~(trust : usage_trust) =
  let outcome = usage_trust_to_string trust in
  Prometheus.inc_counter usage_trust_outcome_metric
    ~labels:[ ("keeper", keeper_name); ("outcome", outcome) ] ();
  match trust with
  | Usage_untrusted reasons ->
    List.iter
      (fun reason ->
        Prometheus.inc_counter usage_anomaly_reason_metric
          ~labels:[ ("keeper", keeper_name); ("reason", reason) ] ())
      reasons;
    let warns_operator = Keeper_usage_trust.warns_operator trust in
    let log_usage =
      if warns_operator then Log.Keeper.warn else Log.Keeper.info
    in
    log_usage
      "#9959 usage_anomaly keeper=%s reasons=[%s] severity=%s — upstream \
       fix tracked in jeong-sik/oas#1181; cost accounting is suppressed \
       to 0.0 for this turn by [usage_trust_is_trusted] gate."
      keeper_name
      (String.concat "," reasons)
      (if warns_operator then "warn" else "info")
  | Usage_missing | Usage_trusted -> ()

let record_keeper_total_cost_usd ~keeper_name ~total_cost_usd =
  let labels = [ ("keeper_name", keeper_name) ] in
  Prometheus.register_gauge
    ~name:Keeper_metrics.metric_keeper_total_cost_usd
    ~help:keeper_total_cost_usd_help
    ~labels
    ();
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_total_cost_usd
    ~labels
    total_cost_usd

let record_keeper_idle_seconds ~keeper_name ~idle_seconds =
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_idle_seconds
    ~labels:[ ("keeper_name", keeper_name) ]
    (float_of_int (max 0 idle_seconds))

let turn_mode_to_string = function
  | Tool_use -> "tool_use"
  | Text_response -> "text_response"
  | Skip_text -> "skip_text"
  | Noop -> "noop"

let turn_mode_of_string (raw : string) : turn_mode option =
  match String.trim raw with
  | "tool_use" -> Some Tool_use
  | "text_response" -> Some Text_response
  | "skip_text" -> Some Skip_text
  | "noop" -> Some Noop
  | _ -> None

let work_kind_of_turn_mode = function
  | Tool_use -> "tool_use"
  | Noop -> "noop"
  | Text_response | Skip_text -> "text_turn"

let is_observation_only_tool_name name =
  not (Keeper_tool_disclosure.is_execution_progress_tool_name name)

let has_substantive_tool_calls (tools_used : string list) : bool =
  List.exists Keeper_tool_disclosure.is_execution_progress_tool_name tools_used

(** A cycle is noop when it produced no text AND all tools used (if any)
    are passive-status only (e.g. board_list, context_status).  A turn whose
    only tool is a [Claim_context] action such as [keeper_task_claim] is NOT
    a noop: claiming a task mutates server-side assignment state and is the
    documented first step of the multi-turn task lifecycle (claim -> act ->
    done) per the prompt.  The noop-backoff was originally introduced in
    #7168 to penalise the [board_list]-only pattern; sweeping
    [Claim_context] into noop was an unintended side-effect that pinned
    real keepers at the 8x cooldown cap. *)
let is_noop_cycle ~has_text ~(tools_used : string list) : bool =
  not has_text
  && List.for_all Keeper_tool_disclosure.is_passive_status_tool_name tools_used

let visible_run_validation (result : Keeper_agent_run.run_result) :
    Agent_sdk.Raw_trace.run_validation option =
  match result.run_validation with
  | Some v when v.ok && (v.evidence <> [] || v.has_file_write) -> Some v
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

let error_category_of_no_result_outcome ~outcome ~error =
  match outcome with
  | "error" | "partial" -> (
      match error with
      | Some e when String.length e > 0 ->
          let e_lower = String.lowercase_ascii e in
          let starts_with prefix =
            String.starts_with e_lower ~prefix
          in
          let contains needle =
            string_contains_substring ~needle e_lower
          in
          (* starts_with checks first (more specific), then contains *)
          if starts_with "invalid request" then Some "invalid_request"
          else if starts_with "network error" then Some "network_error"
          else if starts_with "internal error" then Some "internal_error"
          else if starts_with "input to" then Some "input_budget_exceeded"
          (* contains checks second (broader, order matters) *)
          else if contains "turn outcome ambiguous" then Some "ambiguous_side_effect"
          else if contains "connection_failure"
                  || contains "connection refused" then Some "network_error"
          else if contains "timeout" || contains "timed out" then Some "timeout"
          else if contains "context length"
                  || contains "token budget" then Some "input_budget_exceeded"
          else Some "other"
      | Some _ | None -> Some "unknown")
  | _ -> None

let has_visible_tool_signal (result : Keeper_agent_run.run_result) : bool =
  has_substantive_tool_calls result.tools_used
  || Option.is_some (visible_run_validation result)

let validated_evidence_preview
    (v : Agent_sdk.Raw_trace.run_validation) : string =
  if v.has_file_write then "(validated evidence: file_write)"
  else
    match v.tool_names with
    | [] -> "(validated evidence)"
    | names ->
      Printf.sprintf "(validated evidence: %s)"
        (String.concat ", " names)

let accountability_evidence_refs
    ~(trace_id : string)
    ~(turn_number : int)
    ~(result : Keeper_agent_run.run_result)
    ~(validated_evidence : Agent_sdk.Raw_trace.run_validation option) =
  let tool_refs =
    let stay_silent = Tool_name.Keeper.to_string Tool_name.Keeper.Stay_silent in
    result.tools_used
    |> List.filter_map (fun tool_name ->
           let trimmed = String.trim tool_name in
           if trimmed = "" || String.equal trimmed stay_silent then None
           else Some ("tool:" ^ trimmed))
  in
  let validation_refs =
    match validated_evidence with
    | Some validation ->
        let base =
          validation.evidence
          |> List.map String.trim
          |> List.filter (fun entry -> entry <> "")
          |> List.map (fun entry -> "validation:" ^ entry)
        in
        if validation.has_file_write then
          "validation:file_write" :: base
        else
          base
    | None -> []
  in
  let turn_refs = [ Printf.sprintf "turn:%s:%d" trace_id turn_number ] in
  tool_refs @ validation_refs @ turn_refs

let scheduled_autonomous_outcome_for_result
    (result : Keeper_agent_run.run_result) :
    scheduled_autonomous_cycle_outcome =
  scheduled_autonomous_outcome_of_result
    ~has_text:(String.trim result.response_text <> "")
    ~has_tool_calls:(has_visible_tool_signal result)

let turn_mode_of_result (result : Keeper_agent_run.run_result) : turn_mode =
  let text = String.trim result.response_text in
  if has_visible_tool_signal result then Tool_use
  else if text = "" then Noop
  else if String.starts_with ~prefix:"SKIP:" text then Skip_text
  else Text_response

let turn_mode_of_json (json : Yojson.Safe.t) : turn_mode option =
  match Safe_ops.json_string_opt "turn_mode" json with
  | Some raw -> turn_mode_of_string raw
  | None ->
      (match Safe_ops.json_string_opt "selected_mode" json with
       | Some raw -> turn_mode_of_string raw
       | None ->
           match Safe_ops.json_string_opt "work_kind" json with
           | Some "tool_use" -> Some Tool_use
           | Some "noop" -> Some Noop
           | Some "text_turn" -> Some Text_response
           | _ -> None)

let work_kind_of_json (json : Yojson.Safe.t) : string option =
  match turn_mode_of_json json with
  | Some mode -> Some (work_kind_of_turn_mode mode)
  | None ->
      (match Safe_ops.json_string_opt "work_kind" json with
       | Some raw ->
           let value = String.trim raw in
           if value = "" then None else Some value
       | None -> None)

let observed_triggers_of_observation
    ?meta
    (observation : Keeper_world_observation.world_observation) : string list =
  let triggers = ref [] in
  let add trigger = triggers := trigger :: !triggers in
  if observation.pending_mentions <> [] then add "direct_mention";
  if observation.pending_board_events <> [] then add "board_activity";
  if observation.pending_scope_messages <> [] then add "scope_message";
  if observation.unclaimed_task_count > 0 then add "new_unclaimed_task";
  if observation.claimable_task_count > 0 then add "claimable_task";
  if observation.provider_capacity_blocked_task_count > 0 then
    add "provider_capacity_blocked_backlog";
  if observation.failed_task_count > 0 then add "failed_task";
  let _ = meta in
  if observation.pending_verification_count > 0 then
    add "pending_verification";
  if observation.active_goals <> [] && observation.idle_seconds > 0 then
    add "idle_timeout_candidate";
  if Option.is_some observation.worktree_change_summary then add "worktree_change";
  List.rev !triggers

let normalized_work_discovery_sources (meta : keeper_meta) =
  match meta.work_discovery_sources with
  | None -> None
  | Some sources ->
      Some
        (sources
         |> List.map (fun source ->
                source |> String.trim |> String.lowercase_ascii)
         |> List.filter (fun source -> source <> ""))

let work_discovery_sources_allow ~default_allowed ~matches meta =
  match normalized_work_discovery_sources meta with
  | None -> default_allowed
  | Some [] -> default_allowed
  | Some sources -> List.exists matches sources

let work_discovery_allows_task_claim meta =
  work_discovery_sources_allow ~default_allowed:true ~matches:(function
    | "unclaimed_tasks"
    | "claimable_tasks"
    | "task_claim"
    | "claim" -> true
    | _ -> false)
    meta

let work_discovery_allows_task_audit meta =
  work_discovery_sources_allow ~default_allowed:true ~matches:(function
    | "stale_tasks"
    | "failed_tasks"
    | "task_audit"
    | "orphan_tasks" -> true
    | _ -> false)
    meta

let work_discovery_allows_board_cleanup meta =
  work_discovery_sources_allow ~default_allowed:false ~matches:(function
    | "board_cleanup"
    | "board_curation"
    | "zombie_board_posts" -> true
    | _ -> false)
    meta

let observed_affordances_of_observation
    ?meta
    (observation : Keeper_world_observation.world_observation) : string list =
  let affordances = ref [] in
  let add affordance = affordances := affordance :: !affordances in
  if observation.pending_mentions <> [] then add "reply_in_room";
  if observation.pending_board_events <> [] then add "board_post_or_comment";
  let source_allows_board_cleanup =
    match meta with
    | Some meta -> work_discovery_allows_board_cleanup meta
    | None -> false
  in
  if List.length observation.pending_board_events >= 2
     || (observation.work_discovery_due && source_allows_board_cleanup)
  then add "board_curation";
  if observation.pending_scope_messages <> [] then add "message_sweep";
  let source_allows_task_claim =
    match meta with
    | Some meta -> work_discovery_allows_task_claim meta
    | None -> true
  in
  let source_allows_task_audit =
    match meta with
    | Some meta -> work_discovery_allows_task_audit meta
    | None -> true
  in
  if observation.provider_capacity_blocked_task_count > 0 then
    add "provider_capacity_blocked";
  if
    observation.claimable_task_count > 0
    && observation.provider_capacity_blocked_task_count = 0
    && source_allows_task_claim
  then
    add "task_claim";
  if observation.failed_task_count > 0 && source_allows_task_audit then
    add "task_audit";
  if observation.pending_verification_count > 0 then
    add "task_verify";
  if observation.work_discovery_due then add "work_discovery";
  if Option.is_some observation.worktree_change_summary then add "inspect_worktree_delta";
  List.rev !affordances

let response_requests_confirmation (text : string) : bool =
  let trimmed = String.trim text in
  trimmed <> ""
  && (String.contains trimmed '?'
      || string_contains_substring_ci ~needle:"would you like" trimmed
      || string_contains_substring_ci ~needle:"do you want" trimmed
      || string_contains_substring_ci ~needle:"let me know" trimmed
      || string_contains_substring_ci ~needle:"어떻게 할까" trimmed
      || string_contains_substring_ci ~needle:"할까" trimmed)
