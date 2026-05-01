(** Keeper_unified_metrics — Observation helpers, decision records, and
    metrics update for the unified keeper cycle.

    Extracted from keeper_unified_turn.ml to reduce godfile size.
    All functions here are pure or write-only (JSONL/SSE); no keeper
    lifecycle state is owned by this module.

    @since 0.120.0 *)

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

let cdal_mode_violations_ref_suffix = "evidence/mode_violations.json"

let cdal_raw_evidence_ref_count (proof : Oas.Cdal_proof.t) : int =
  List.length proof.raw_evidence_refs

let cdal_violation_ref_count (proof : Oas.Cdal_proof.t) : int =
  proof.raw_evidence_refs
  |> List.filter (String.ends_with ~suffix:cdal_mode_violations_ref_suffix)
  |> List.length

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

let classify_usage_trust ~(usage_reported : bool)
    ~(usage : Oas.Types.api_usage)
    ~(model_used : string)
    ~(resolved_model_id : string)
    ~(context_max : int) : usage_trust =
  Keeper_usage_trust.classify ~usage_reported ~usage ~model_used
    ~resolved_model_id ~context_max

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
  Prometheus.inc_counter
    Prometheus.metric_keeper_context_max_observed
    ~labels:[
      ("keeper", keeper);
      ("model_used", model_used);
      ("resolved_model_id", resolved_model_id);
      ("context_max_bucket", context_max_bucket context_max);
    ] ()

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
    Prometheus.metric_keeper_turn_latency_bucket
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
  let model_used = label_or_unknown raw in
  Provider_adapter.provider_of_model_label model_used

let record_turn_latency_by_model_bucket
    ~(keeper : string)
    ~(channel : string)
    ~(model_used : string)
    ~(resolved_model_id : string)
    ~(cascade_profile : string)
    ~(latency_ms : int) : unit =
  let bucket = turn_latency_bucket latency_ms in
  let model_used = label_or_unknown model_used in
  let resolved_model_id = label_or_unknown resolved_model_id in
  let cascade_profile = label_or_unknown cascade_profile in
  Prometheus.inc_counter
    Prometheus.metric_keeper_turn_latency_by_model_bucket
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

let estimate_trusted_usage_cost_usd ~usage_trusted ~model usage =
  if usage_trusted then
    Keeper_hooks_oas.estimate_usage_cost_usd ~model usage
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
let usage_trust_outcome_metric = "masc_keeper_usage_trust_total"
let usage_anomaly_reason_metric = "masc_keeper_usage_anomaly_reason_total"

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
    Log.Keeper.warn
      "#9959 usage_anomaly keeper=%s reasons=[%s] — upstream fix \
       tracked in jeong-sik/oas#1181; cost accounting is suppressed \
       to 0.0 for this turn by [usage_trust_is_trusted] gate."
      keeper_name (String.concat "," reasons)
  | Usage_missing | Usage_trusted -> ()

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
    Oas.Raw_trace.run_validation option =
  match result.run_validation with
  | Some v when v.ok && (v.evidence <> [] || v.has_file_write) -> Some v
  | _ -> None

let telemetry_reported_of_result
    (result : Keeper_agent_run.run_result) : bool =
  Option.is_some result.inference_telemetry

let structurally_unmetered_provider (provider : string) : bool =
  Provider_adapter.is_structurally_unmetered_provider provider

let coverage_reason_of_result
    (result : Keeper_agent_run.run_result) : string option =
  let telemetry_reported = telemetry_reported_of_result result in
  if result.usage_reported && telemetry_reported then None
  else
    let provider =
      Keeper_agent_run.surface_model_used result
      |> Keeper_hooks_oas.provider_of_model
    in
    match result.usage_reported, telemetry_reported with
    | false, false ->
        if String.equal result.tool_surface.tool_requirement "none"
           && structurally_unmetered_provider provider
        then Some "text_only_unmetered"
        else Some "missing_usage_and_inference"
    | false, true -> Some "missing_usage"
    | true, false -> Some "missing_inference"
    | true, true -> None

let coverage_stage_of_result
    (result : Keeper_agent_run.run_result) : string option =
  if result.usage_reported && telemetry_reported_of_result result
  then None
  else Some "oas"

let has_visible_tool_signal (result : Keeper_agent_run.run_result) : bool =
  has_substantive_tool_calls result.tools_used
  || Option.is_some (visible_run_validation result)

let validated_evidence_preview
    (v : Oas.Raw_trace.run_validation) : string =
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
    ~(validated_evidence : Oas.Raw_trace.run_validation option) =
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
  if observation.failed_task_count > 0 then add "failed_task";
  let _ = meta in
  if observation.pending_verification_count > 0 then
    add "pending_verification";
  if observation.active_goals <> [] && observation.idle_seconds > 0 then
    add "idle_timeout_candidate";
  if Option.is_some observation.worktree_change_summary then add "worktree_change";
  List.rev !triggers

let observed_affordances_of_observation
    ?meta
    (observation : Keeper_world_observation.world_observation) : string list =
  let affordances = ref [] in
  let add affordance = affordances := affordance :: !affordances in
  if observation.pending_mentions <> [] then add "reply_in_room";
  if observation.pending_board_events <> [] then add "board_post_or_comment";
  if observation.pending_scope_messages <> [] then add "message_sweep";
  if observation.claimable_task_count > 0 then add "task_claim";
  if observation.failed_task_count > 0 then add "task_audit";
  let _ = meta in
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

let decision_id ~(meta : keeper_meta) ~(ts : float) ~(suffix_seed : string) : string =
  let digest =
    Digest.to_hex
      (Digest.string
         (Printf.sprintf "%s|%s|%.6f|%s"
            meta.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id) ts suffix_seed))
  in
  Printf.sprintf "dec-%Ld-%s"
    (Int64.of_float (ts *. 1000.0))
    (String.sub digest 0 8)

let tool_call_detail_to_json
    (detail : Keeper_agent_run.tool_call_detail)
  : Yojson.Safe.t =
  `Assoc
    [ ("tool_name", `String detail.tool_name)
    ; ("provider", `String detail.provider)
    ; ("outcome", `String detail.outcome)
    ; ("latency_ms", `Float detail.latency_ms)
    ]

let provider_context_json ~(meta : keeper_meta)
    (result : Keeper_agent_run.run_result option) =
  match result with
  | Some r ->
      let cascade_name, selected_model, candidate_models =
        match r.cascade_observation with
        | Some observation ->
            ( Keeper_cascade_profile.runtime_name_to_string
                observation.cascade_name,
              observation.selected_model,
              observation.candidate_models )
        | None ->
            ( meta.cascade_name,
              Some (Keeper_agent_run.surface_model_used r),
              [] )
      in
      `Assoc
        [ ("cascade_name", `String cascade_name)
        ; ( "selected_model",
            Json_util.string_opt_to_json selected_model )
        ; ( "candidate_models",
            `List (List.map (fun value -> `String value) candidate_models) )
        ]
  | None ->
      `Assoc
        [ ("cascade_name", `String meta.cascade_name)
        ; ("selected_model", `Null)
        ; ( "candidate_models",
            `List
              (List.map
                 (fun value -> `String value)
                 (Keeper_model_labels.configured_model_labels_of_meta meta)) )
        ]

let tool_contract_json ~(tool_call_count : int) ~(tools_used : string list)
    (result : Keeper_agent_run.run_result option) =
  let requirement, required_tool_names, missing_required_tool_names =
    match result with
    | Some r ->
        ( r.tool_surface.tool_requirement,
          r.tool_surface.required_tool_names,
          r.tool_surface.missing_required_tool_names )
    | None -> ("unknown", [], [])
  in
  `Assoc
    [ ("requirement", `String requirement)
    ; ( "required_tool_names",
        `List (List.map (fun value -> `String value) required_tool_names) )
    ; ( "missing_required_tool_names",
        `List (List.map (fun value -> `String value) missing_required_tool_names) )
    ; ("tool_call_count", `Int tool_call_count)
    ; ("tools_used", `List (List.map (fun value -> `String value) tools_used))
    ]

let append_decision_record
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(latency_ms : int)
    ?(semaphore_wait_ms : int = 0)
    ~(outcome : string)
    ?(degraded_retry_applied = false)
    ?degraded_retry_cascade
    ?fallback_reason
    ?turn_mode
    ?social_state
    ?deliberation_execution
    ?(result : Keeper_agent_run.run_result option = None)
    ?error
    ?terminal_reason
    () : unit =
  let now_ts = Time_compat.now () in
  let trigger_signals = observed_triggers_of_observation ~meta observation in
  let affordances = observed_affordances_of_observation ~meta observation in
  let tools_used =
    match result with
    | Some r -> r.tools_used
    | None -> []
  in
  let response_preview =
    match result with
    | Some r when String.trim r.response_text <> "" ->
        Some (short_preview r.response_text)
    | _ -> None
  in
  let tool_call_count =
    match result with
    | Some r -> r.tool_calls_made
    | None -> 0
  in
  let tool_calls =
    match result with
    | Some r -> r.tool_calls
    | None -> []
  in
  let ( _turn_lane
      , _turn_tool_choice
      , turn_thinking_enabled
      , _turn_thinking_budget
      , _turn_prompt_fingerprint
      , _turn_trace_id
      , _turn_session_id
      , _turn_number
      , turn_id_opt
      , task_id_opt
      , turn_goal_ids_opt
      , _sandbox_profile
      , _network_mode
      , approval_mode ) =
    Keeper_tool_call_log.get_turn_context ~keeper_name:meta.name ()
  in
  let turn_id =
    Option.value ~default:meta.runtime.usage.total_turns turn_id_opt
  in
  let task_id =
    match task_id_opt with
    | Some _ as value -> value
    | None -> Keeper_runtime_contract.current_task_id_opt meta
  in
  let goal_ids =
    match turn_goal_ids_opt with
    | Some values -> values
    | None -> meta.active_goal_ids
  in
  let goal_id =
    match goal_ids with
    | value :: _ -> Some value
    | [] -> None
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_contract_json ~config meta
  in
  let pending_approval_count =
    Keeper_approval_queue.pending_count_for_keeper ~keeper_name:meta.name
  in
  let claim_executed =
    List.exists Keeper_tool_disclosure.is_claim_tool_name tools_used
  in
  let social_fields =
    match social_state with
    | None -> []
    | Some state ->
        let option_field key = function
          | Some value -> (key, `String value)
          | None -> (key, `Null)
        in
        [
          ("social_model", `String state.Social.social_model);
          ("belief_summary", `String state.belief_summary);
          option_field "active_desire" state.active_desire;
          option_field "current_intention" state.current_intention;
          option_field "blocker" state.blocker;
          option_field "need" state.need;
          ("speech_act", `String (Social.speech_act_to_string state.speech_act));
          ( "delivery_surface",
            `String
              (Social.delivery_surface_to_string state.delivery_surface) );
        ]
  in
  let turn_mode =
    match turn_mode, result with
    | Some mode, _ -> Some mode
    | None, Some r -> Some (turn_mode_of_result r)
    | None, None -> None
  in
  let turn_mode_label = Option.map turn_mode_to_string turn_mode in
  let suffix_seed =
    match response_preview, error with
    | Some preview, _ -> preview
    | None, Some err -> err
    | None, None -> Option.value ~default:outcome turn_mode_label
  in
  let terminal_reason =
    match terminal_reason with
    | Some reason -> reason
    | None -> (
        match outcome, error with
        | "success", _ -> Keeper_turn_terminal.success ()
        | _, Some err -> Keeper_turn_terminal.of_legacy_error_text err
        | _ -> Keeper_turn_terminal.of_code "unknown_error")
  in
  let json =
    `Assoc
      ([
        ("id", `String (decision_id ~meta ~ts:now_ts ~suffix_seed));
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("audience", `String "internal_human_only");
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("generation", `Int meta.runtime.generation);
        ("turn_id", `Int turn_id);
        ("keeper_name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("task_id", Json_util.string_opt_to_json task_id);
        ("goal_id", Json_util.string_opt_to_json goal_id);
        ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) goal_ids));
        ("runtime_contract", runtime_contract);
        ("terminal_reason", Keeper_turn_terminal.to_json terminal_reason);
        ("provider_context", provider_context_json ~meta result);
        ("tool_contract", tool_contract_json ~tool_call_count ~tools_used result);
        ("pending_approval_count", `Int pending_approval_count);
        ("approval_mode", Json_util.string_opt_to_json approval_mode);
        ("channel", `String (decision_channel_of_observation observation));
        ("outcome", `String outcome);
        ("degraded_retry_applied", `Bool degraded_retry_applied);
        ( "degraded_retry_cascade",
          Json_util.string_opt_to_json degraded_retry_cascade );
        ("fallback_reason", Json_util.string_opt_to_json fallback_reason);
        ("turn_mode", Json_util.string_opt_to_json turn_mode_label);
        ("latency_ms", `Int latency_ms);
        ("semaphore_wait_ms", `Int semaphore_wait_ms);
        ("trigger_signals", `List (List.map (fun s -> `String s) trigger_signals));
        ("observed_affordances", `List (List.map (fun s -> `String s) affordances));
        ( "observation",
          `Assoc
            [
              ("pending_mentions", `Int (List.length observation.pending_mentions));
              ("pending_board_events", `Int (List.length observation.pending_board_events));
              ("pending_scope_messages", `Int (List.length observation.pending_scope_messages));
              ("active_goals", `Int (List.length observation.active_goals));
              ("idle_seconds", `Int observation.idle_seconds);
              ("context_ratio", `Float observation.context_ratio);
              ("unclaimed_task_count", `Int observation.unclaimed_task_count);
              ("claimable_task_count", `Int observation.claimable_task_count);
              ( "claim_blocked_task_count",
                `Int
                  (max 0
                     (observation.unclaimed_task_count
                      - observation.claimable_task_count)) );
              ("failed_task_count", `Int observation.failed_task_count);
              ("pending_verification_count", `Int observation.pending_verification_count);
              ("active_agent_count", `Int observation.active_agent_count);
              ("worktree_change_detected", `Bool (Option.is_some observation.worktree_change_summary));
            ] );
        ("tool_call_count", `Int tool_call_count);
        ("tools_used", `List (List.map (fun s -> `String s) tools_used));
        ("tool_calls", `List (List.map tool_call_detail_to_json tool_calls));
        ("claim_absolute_available", `Bool (observation.unclaimed_task_count > 0));
        ("claim_matched_available", `Bool (observation.claimable_task_count > 0));
        ("claim_was_available", `Bool (observation.claimable_task_count > 0));
        ("claim_executed", `Bool claim_executed);
        ( "action_source",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.action_source_of_execution_result execution
              |> Keeper_deliberation.action_source_to_json
          | None -> `Null );
        ( "deliberation_execution",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.execution_result_to_json execution
          | None -> `Null );
        ( "response_preview",
          match response_preview with
          | Some preview -> `String preview
          | None -> `Null );
        ( "response_preview_2000",
          match result with
          | Some r when String.trim r.response_text <> "" ->
              `String (short_preview ~max_len:2000 r.response_text)
          | _ -> `Null );
        ( "response_requests_confirmation",
          `Bool
            (match result with
             | Some r -> response_requests_confirmation r.response_text
             | None -> false) );
        ( "error",
          match error with
          | Some reason -> `String reason
          | None -> `Null );
        ( "trace_ref",
          match result with
          | Some { trace_ref = Some trace_ref; _ } ->
              Oas.Raw_trace.run_ref_to_yojson trace_ref
          | _ -> `Null );
        ( "run_validation",
          match result with
          | Some { run_validation = Some validation; _ } ->
              Oas.Raw_trace.run_validation_to_yojson validation
          | _ -> `Null );
        ( "cdal_proof",
          match result with
          | Some { proof = Some p; _ } ->
              `Assoc
                [
                  ("run_id", `String p.Oas.Cdal_proof.run_id);
                  ( "result_status",
                    Oas.Cdal_proof.result_status_to_yojson p.result_status );
                  ("tool_trace_count", `Int (List.length p.tool_trace_refs));
                ]
          | _ -> `Null );
        ( "telemetry",
          match result with
          | Some r ->
              let surface_model_used = Keeper_agent_run.surface_model_used r in
              let resolved_model_id =
                Keeper_agent_run.surface_resolved_model_id r
              in
              let telemetry_reported = telemetry_reported_of_result r in
              let coverage_reason = coverage_reason_of_result r in
              let coverage_stage = coverage_stage_of_result r in
              let usage_trust =
                classify_usage_trust
                  ~usage_reported:r.usage_reported
                  ~usage:r.usage
                  ~model_used:surface_model_used
                  ~resolved_model_id
                  ~context_max:0
              in
              let thinking_enabled_field =
                match turn_thinking_enabled with
                | Some b -> [("thinking_enabled", `Bool b)]
                | None -> []
              in
              let cascade_fields =
                match r.cascade_observation with
                | Some co ->
                    let cascade_name =
                      Keeper_cascade_profile.runtime_name_to_string
                        co.cascade_name
                    in
                    [
                      ("cascade_name", `String cascade_name);
                      ("strategy", Json_util.string_opt_to_json co.strategy);
                      ("primary_model", match co.primary_model with Some m -> `String m | None -> `Null);
                      ("selected_model", match co.selected_model with Some m -> `String m | None -> `Null);
                      ("fallback_applied", `Bool co.fallback_applied);
                      ("fallback_hops", match co.fallback_hops with Some n -> `Int n | None -> `Int 0);
                      ("candidate_models", `List (List.map (fun s -> `String s) co.candidate_models));
                    ]
                | None -> []
              in
              let tool_surface_fields =
                [
                  ("turn_lane", `String r.tool_surface.turn_lane);
                  ("tool_surface_class", `String r.tool_surface.tool_surface_class);
                  ("tool_requirement", `String r.tool_surface.tool_requirement);
                  ("visible_tool_count", `Int r.tool_surface.visible_tool_count);
                  ("tool_gate_enabled", `Bool r.tool_surface.tool_gate_enabled);
                  ( "tool_surface_fallback_used",
                    `Bool r.tool_surface.tool_surface_fallback_used );
                  ( "required_tool_names",
                    `List
                      (List.map
                         (fun name -> `String name)
                         r.tool_surface.required_tool_names) );
                  ( "missing_required_tool_names",
                    `List
                      (List.map
                         (fun name -> `String name)
                         r.tool_surface.missing_required_tool_names) );
                  ("config_root", `String r.tool_surface.config_root);
                  ( "cascade_config_path",
                    match r.tool_surface.cascade_config_path with
                    | Some path -> `String path
                    | None -> `Null );
                  ("gemini_mcp_disabled", `Bool r.tool_surface.gemini_mcp_disabled);
                  ( "approval_mode_effective",
                    match r.tool_surface.approval_mode_effective with
                    | Some mode -> `String mode
                    | None -> `Null );
                  ("approval_mode_derived", `Bool r.tool_surface.approval_mode_derived);
                ]
              in
                let stop_reason_str =
                  match r.stop_reason with
                  | Oas_worker.Completed -> "completed"
                  | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
                      Printf.sprintf "turn_budget_exhausted(%d/%d)" turns_used limit
                  | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
                      (match tool_name with
                       | Some tool ->
                           Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
                       | None ->
                           Printf.sprintf "mutation_boundary(%d)" turns_used)
                in
              let inference_fields =
                match r.inference_telemetry with
                | Some t ->
                    let timings_fields =
                      match t.timings with
                      | Some ti ->
                          (* hw_decode_tokens_per_second: unambiguous alias of
                             provider_tokens_per_second. Both read ti.predicted_per_second
                             (eval_count / eval_duration from Ollama), which is the true
                             hardware decode rate — distinct from the wall-clock
                             tokens_per_second (output_tokens / latency_ms) below. Dashboards
                             should prefer hw_decode_* name; legacy name kept for backward compat. *)
                          [
                            ("prompt_ms", match ti.prompt_ms with Some v -> `Float v | None -> `Null);
                            ("predicted_ms", match ti.predicted_ms with Some v -> `Float v | None -> `Null);
                            ("provider_tokens_per_second", match ti.predicted_per_second with Some v -> `Float v | None -> `Null);
                            ("hw_decode_tokens_per_second", match ti.predicted_per_second with Some v -> `Float v | None -> `Null);
                            ("prompt_per_second", match ti.prompt_per_second with Some v -> `Float v | None -> `Null);
                            ("cache_n", match ti.cache_n with Some v -> `Int v | None -> `Null);
                          ]
                      | None -> []
                    in
                    [
                      ("system_fingerprint", match t.system_fingerprint with Some s -> `String s | None -> `Null);
                      ("reasoning_tokens", match t.reasoning_tokens with Some n -> `Int n | None -> `Null);
                      ("request_latency_ms", `Int t.request_latency_ms);
                    ] @ timings_fields
                | None -> []
              in
              let usage_fields =
                if r.usage_reported then
                  [
                    ("input_tokens", `Int r.usage.input_tokens);
                    ("output_tokens", `Int r.usage.output_tokens);
                    ("cache_creation_tokens", `Int r.usage.cache_creation_input_tokens);
                    ("cache_read_tokens", `Int r.usage.cache_read_input_tokens);
                    ("cost_usd", match r.usage.cost_usd with Some c -> `Float c | None -> `Null);
                    ( "tokens_per_second",
                      if usage_trust_is_trusted usage_trust && latency_ms > 0 then
                        `Float
                          (float_of_int r.usage.output_tokens
                           /. (float_of_int latency_ms /. 1000.0))
                      else `Null );
                  ]
                  @ usage_trust_json_fields usage_trust
                else
                  [
                    ("input_tokens", `Null);
                    ("output_tokens", `Null);
                    ("cache_creation_tokens", `Null);
                    ("cache_read_tokens", `Null);
                    ("cost_usd", `Null);
                    ("tokens_per_second", `Null);
                  ]
                  @ usage_trust_json_fields usage_trust
              in
              `Assoc ([
                ("model_used", `String surface_model_used);
                ("resolved_model_id", `String resolved_model_id);
                ("outcome", `String "success");
                ("turn_count", `Int r.turn_count);
                ("stop_reason", `String stop_reason_str);
                ("usage_reported", `Bool r.usage_reported);
                ("telemetry_reported", `Bool telemetry_reported);
                ( "coverage_stage",
                  match coverage_stage with
                  | Some stage -> `String stage
                  | None -> `Null );
                ( "coverage_reason",
                  match coverage_reason with
                  | Some reason -> `String reason
                  | None -> `Null );
              ] @ usage_fields @ thinking_enabled_field @ inference_fields @ cascade_fields @ tool_surface_fields)
          | None ->
              (* Partial telemetry for error turns: record what we know.
                 Without this, 90%+ of turns have no telemetry at all. *)
              let cascade_models =
                Keeper_model_labels.configured_model_labels_of_meta meta
              in
              let error_category =
                match error with
                | Some e when String.length e > 0 ->
                  let e_lower = String.lowercase_ascii e in
                  let starts_with prefix =
                    String.length e_lower >= String.length prefix
                    && String.sub e_lower 0 (String.length prefix) = prefix
                  in
                  let contains needle =
                    string_contains_substring ~needle e_lower
                  in
                  (* starts_with checks first (more specific), then contains *)
                  if starts_with "invalid request" then "invalid_request"
                  else if starts_with "network error" then "network_error"
                  else if starts_with "internal error" then "internal_error"
                  else if starts_with "input to" then "input_budget_exceeded"
                  (* contains checks second (broader, order matters) *)
                  else if contains "turn outcome ambiguous" then "ambiguous_side_effect"
                  else if contains "connection_failure"
                          || contains "connection refused" then "network_error"
                  else if contains "timeout" || contains "timed out" then "timeout"
                  else if contains "context length"
                          || contains "token budget" then "input_budget_exceeded"
                  else "other"
                | _ -> "unknown"
              in
              `Assoc [
                ("cascade_name", `String meta.cascade_name);
                ("candidate_models", `List (List.map (fun s -> `String s) cascade_models));
                ("error_category", `String error_category);
                ("outcome", `String "error");
                ("usage_reported", `Bool false);
                ("telemetry_reported", `Bool false);
                ("coverage_stage", `String "unknown");
                ("coverage_reason", `String "error_turn");
              ] );
      ]
      @ social_fields)
  in
  try append_jsonl_line (keeper_decision_log_path config meta.name) json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Keeper.warn "append decision record failed for %s: %s"
        meta.name (Printexc.to_string exn)

(** Observe tool call history from run_result to update keeper metrics.
    No action_taken type — we observe what the agent did, not classify it. *)
let update_metrics_from_result (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    ?(is_autonomous_turn = true)
    ?(update_proactive_rt = true)
    ?social_state
    ?social_transition_reason
    ?(context_max = 0)
    (result : Keeper_agent_run.run_result) : keeper_meta =
  let now_ts = Time_compat.now () in
  let surface_model_used = Keeper_agent_run.surface_model_used result in
  let resolved_model_id = Keeper_agent_run.surface_resolved_model_id result in
  let usage_trust =
    classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
      ~model_used:surface_model_used
      ~resolved_model_id
      ~context_max
  in
  (* #9959: surface classification into Prometheus exactly once per
     turn. Other [classify_usage_trust] call sites serialize the
     trust into JSONL but do not bump the counter. *)
  record_usage_trust ~keeper_name:meta.name ~trust:usage_trust;
  let usage_trusted = usage_trust_is_trusted usage_trust in
  let trusted_input_tokens =
    if usage_trusted then result.usage.input_tokens else 0
  in
  let trusted_output_tokens =
    if usage_trusted then result.usage.output_tokens else 0
  in
  let trusted_total_tokens =
    if usage_trusted then Keeper_exec_context.total_tokens result.usage else 0
  in
  (* Use cascade_observation.selected_model (canonical, no :latest suffix)
     instead of parsing model strings and stripping :latest manually.
     surface_model_used already extracts this from cascade_observation.
     Removes L3 (Cascade_config.parse_model_strings direct call) and
     L6 (strip_latest model ID parsing) boundary violations. See #5626. *)
  let used_model_id = surface_model_used in
  let turn_cost =
    estimate_trusted_usage_cost_usd
      ~usage_trusted
      ~model:used_model_id
      result.usage
  in
  let substantive_tool_call_count =
    result.tools_used
    |> List.filter (fun name -> not (is_observation_only_tool_name name))
    |> List.length
  in
  let has_substantive_tools = has_substantive_tool_calls result.tools_used in
  let has_text = String.trim result.response_text <> "" in
  let validated_evidence = visible_run_validation result in
  let has_validated_evidence = Option.is_some validated_evidence in
  let visible_tool_signal_present =
    has_substantive_tools || has_validated_evidence
  in
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
  let is_board_reactive = observation.pending_board_events <> [] in
  let is_mention_reactive = observation.pending_mentions <> [] in
  let rt = meta.runtime in
  let social_state : Social.social_state =
    Option.value social_state
      ~default:
        Social.
          {
            social_model = meta.social_model;
            belief_summary = "not_recorded";
            active_desire = None;
            current_intention = None;
            blocker = None;
            need = None;
            speech_act = Social.Inform;
            delivery_surface = Social.Visible_reply;
          }
  in
  (* #10474: proactive outcome counter for successful cycles. *)
  if update_proactive_rt && is_scheduled_autonomous_cycle then begin
    let outcome =
      if has_substantive_tools then "tool_called"
      else if is_noop_cycle ~has_text ~tools_used:result.tools_used
      then "noop"
      else "tool_called"
    in
    Prometheus.inc_counter Prometheus.metric_keeper_proactive_outcome
      ~labels:[ ("keeper", meta.name); ("outcome", outcome) ]
      ()
  end;
  {
    meta with
    updated_at = now_iso ();
    runtime = { rt with
      usage = {
        total_turns = rt.usage.total_turns + 1;
        total_input_tokens = rt.usage.total_input_tokens + trusted_input_tokens;
        total_output_tokens =
          rt.usage.total_output_tokens + trusted_output_tokens;
        total_tokens =
          rt.usage.total_tokens + trusted_total_tokens;
        total_cost_usd = rt.usage.total_cost_usd +. turn_cost;
        last_turn_ts = now_ts;
        last_model_used = surface_model_used;
        last_input_tokens = trusted_input_tokens;
        last_output_tokens = trusted_output_tokens;
        last_total_tokens = trusted_total_tokens;
        last_latency_ms = latency_ms;
      };
      (* Deterministic scheduled autonomous cycle accounting is separated from
         nondeterministic model output visibility. *)
      proactive_rt = {
        count_total =
          rt.proactive_rt.count_total
          + (if update_proactive_rt && is_scheduled_autonomous_cycle then 1 else 0);
        last_ts =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then now_ts
           else rt.proactive_rt.last_ts);
        visible_count_total =
          rt.proactive_rt.visible_count_total
          + (if update_proactive_rt
               && is_scheduled_autonomous_cycle
               && (has_text || visible_tool_signal_present)
             then 1
             else 0);
        last_visible_ts =
          (if update_proactive_rt
              && is_scheduled_autonomous_cycle
              && (has_text || visible_tool_signal_present)
           then now_ts
           else rt.proactive_rt.last_visible_ts);
        last_outcome =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then
             scheduled_autonomous_outcome_of_result ~has_text
               ~has_tool_calls:visible_tool_signal_present
           else rt.proactive_rt.last_outcome);
        last_reason =
          (if not update_proactive_rt || not is_scheduled_autonomous_cycle
           then rt.proactive_rt.last_reason
           else if has_substantive_tools then
             Printf.sprintf "unified:tools=[%s]"
               (String.concat "," result.tools_used)
           else if has_validated_evidence then
             (match validated_evidence with
              | Some v ->
                Printf.sprintf "unified:validated_evidence(ok=%b,file_write=%b,evidence=%d)"
                  v.ok v.has_file_write (List.length v.evidence)
              | None -> "unified:validated_evidence(unreachable)")
           else if not has_text then
             "unified:"
             ^ scheduled_autonomous_cycle_outcome_to_string Proactive_silent
            else if has_text then "unified:text_response"
            else rt.proactive_rt.last_reason);
        last_preview =
          (if not update_proactive_rt || not is_scheduled_autonomous_cycle
           then rt.proactive_rt.last_preview
           else if has_text then short_preview result.response_text
           else if has_substantive_tools then
             Printf.sprintf "(tools: %s)" (String.concat ", " result.tools_used)
           else
             (match validated_evidence with
              | Some v -> validated_evidence_preview v
              | None -> rt.proactive_rt.last_preview)
          );
        (* Work discovery timestamp only advances when the keeper
           actually used tools in response to the nudge. This is
           intentional: the "Work Discovery Due" prompt block keeps
           being injected until the keeper takes visible action,
           preventing silent cycles from consuming the scan interval. *)
        last_work_discovery_ts =
          (if observation.work_discovery_due && has_substantive_tools then
             now_ts
           else rt.proactive_rt.last_work_discovery_ts);
        work_discovery_count =
          rt.proactive_rt.work_discovery_count
          + (if observation.work_discovery_due && has_substantive_tools then 1
             else 0);
        consecutive_noop_count =
          (if update_proactive_rt && is_scheduled_autonomous_cycle then
             if is_noop_cycle ~has_text ~tools_used:result.tools_used
             then rt.proactive_rt.consecutive_noop_count + 1
             else 0
           else rt.proactive_rt.consecutive_noop_count);
      };
      (* Autonomous action tracking from tool calls *)
      autonomous_action_count =
        rt.autonomous_action_count
        + (if is_autonomous_turn then substantive_tool_call_count else 0);
      autonomous_turn_count =
        rt.autonomous_turn_count + (if is_autonomous_turn then 1 else 0);
      autonomous_text_turn_count =
        rt.autonomous_text_turn_count
        + (if is_autonomous_turn && has_text && not has_substantive_tools then 1 else 0);
      autonomous_tool_turn_count =
        rt.autonomous_tool_turn_count
        + (if is_autonomous_turn && has_substantive_tools then 1 else 0);
      board_reactive_turn_count =
        rt.board_reactive_turn_count + (if is_board_reactive then 1 else 0);
      mention_reactive_turn_count =
        rt.mention_reactive_turn_count + (if is_mention_reactive then 1 else 0);
      noop_turn_count =
        rt.noop_turn_count
        + (if is_autonomous_turn && not has_text && not has_substantive_tools
              && not has_validated_evidence then 1 else 0);
      consecutive_noop_count =
        (if is_autonomous_turn && not has_text && not has_substantive_tools
            && not has_validated_evidence
         then rt.consecutive_noop_count + 1
         else 0);
      (* This timestamp stays scoped to substantive tool actions.
         Validated evidence affects proactive visibility, but it does not
         redefine the autonomous action counter semantics. *)
      last_autonomous_action_at =
        (if is_autonomous_turn && has_substantive_tools
         then now_iso ()
         else rt.last_autonomous_action_at);
      last_speech_act = Social.speech_act_to_string social_state.speech_act;
      last_social_transition_reason =
        (match social_transition_reason with
         | Some reason -> String.trim reason
         | None -> rt.last_social_transition_reason);
      last_active_desire =
        Option.value ~default:"" social_state.active_desire;
      last_current_intention =
        Option.value ~default:"" social_state.current_intention;
      (* A successful turn means the keeper is not blocked.
         Clear unconditionally so stale error strings from previous
         failures do not persist in the runtime JSON and mislead the
         dashboard into showing BLOCKED status.  The social model's
         blocker field is a protocol-level signal; runtime last_blocker
         tracks whether the keeper can make progress. *)
      last_blocker = "";
      last_blocker_class = None;
      last_need = Option.value ~default:"" social_state.need;
    };
  }

let append_metrics_snapshot ~(config : Coord.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(result : Keeper_agent_run.run_result) ~(latency_ms : int)
    ~(turn_cost : float)
    ~(turn_generation : int)
    ~(channel : string)
    ~(snapshot_source : string)
    ~(context_ratio : float)
    ~(context_tokens : int)
    ~(context_max : int)
    ~(message_count : int)
    ~(compaction : Keeper_exec_context.compaction_event)
    ~(handoff_json : Yojson.Safe.t option)
    ?timeout_budget_json ?deliberation_execution () : unit =
  let now_ts = Time_compat.now () in
  let _observation = observation in
  let turn_mode = turn_mode_of_result result in
  let surface_model_used = Keeper_agent_run.surface_model_used result in
  let resolved_model_id = Keeper_agent_run.surface_resolved_model_id result in
  let usage_trust =
    classify_usage_trust
      ~usage_reported:result.usage_reported
      ~usage:result.usage
      ~model_used:surface_model_used
      ~resolved_model_id
      ~context_max
  in
  (* #9953: record the (keeper, model_used, resolved_model_id,
     context_max_bucket) tuple so dashboards can directly count
     drift.  A model whose label takes >1 bucket on a single
     deployment indicates the resolution path produced
     different ceilings on different turns. *)
  record_context_max_observation
    ~keeper:meta.name
    ~model_used:surface_model_used
    ~resolved_model_id
    ~context_max;
  let scheduled_autonomous_outcome =
    if is_scheduled_autonomous_channel channel then
      Some (scheduled_autonomous_outcome_for_result result)
    else None
  in
  let metrics_store = keeper_metrics_store config meta.name in
  let usage_json =
    if result.usage_reported then
      `Assoc
        ([
          ("input_tokens", `Int result.usage.input_tokens);
          ("output_tokens", `Int result.usage.output_tokens);
          ("cache_creation_tokens", `Int result.usage.cache_creation_input_tokens);
          ("cache_read_tokens", `Int result.usage.cache_read_input_tokens);
          ("total_tokens",
           `Int (Keeper_exec_context.total_tokens result.usage));
        ]
        @ usage_trust_json_fields usage_trust)
    else
      `Assoc
        ([
          ("input_tokens", `Null);
          ("output_tokens", `Null);
          ("cache_creation_tokens", `Null);
          ("cache_read_tokens", `Null);
          ("total_tokens", `Null);
        ]
        @ usage_trust_json_fields usage_trust)
  in
  let cost_json =
    if result.usage_reported && usage_trust_is_trusted usage_trust then
      `Float turn_cost
    else `Null
  in
  (* #9943: per-keeper turn-latency bucket counter + WARN if the
     turn crossed the long-turn threshold (default 600s, env-
     overridable).  Emitted once per snapshot write so the
     counter rate matches the JSONL row rate. *)
  record_turn_latency_bucket ~keeper:meta.name ~latency_ms;
  let cascade_profile =
    match result.cascade_observation with
    | Some observation ->
      Keeper_cascade_profile.runtime_name_to_string
        observation.Oas_worker.cascade_name
    | None -> meta.cascade_name
  in
  (* #9933: same latency bucket, split by provider/model/cascade.
     This keeps the existing keeper-only counter stable while making
     timeout-budget burn attributable to a concrete model surface. *)
  record_turn_latency_by_model_bucket
    ~keeper:meta.name
    ~channel
    ~model_used:surface_model_used
    ~resolved_model_id
    ~cascade_profile
    ~latency_ms;
  let snapshot =
    `Assoc
      [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now_ts);
        ("channel", `String channel);
        ("name", `String meta.name);
        ("agent_name", `String meta.agent_name);
        ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
        ("generation", `Int turn_generation);
        ("model_used", `String surface_model_used);
        ("resolved_model_id", `String resolved_model_id);
        ("prompt_fingerprint", `String result.prompt_metrics.fingerprint);
        ("prompt", Keeper_agent_run.prompt_metrics_to_json result.prompt_metrics);
        ( "timeout_budget",
          match timeout_budget_json with
          | Some value -> value
          | None -> `Null );
        ("ctx_composition", Keeper_agent_run.ctx_composition_to_json result.ctx_composition);
        ("usage", usage_json);
        ("usage_trust", `String (usage_trust_to_string usage_trust));
        ( "usage_anomaly_reasons",
          `List
            (List.map
               (fun reason -> `String reason)
               (usage_trust_reasons usage_trust)) );
        ("latency_ms", `Int latency_ms);
        ("cost_usd", cost_json);
        ("context_ratio", `Float context_ratio);
        ("context_tokens", `Int context_tokens);
        ("context_max", `Int context_max);
        ("message_count", `Int message_count);
        ("continuity_state", `Null);
        ("continuity_summary", `String meta.continuity_summary);
        ("compacted", `Bool compaction.applied);
        ("compaction_before_tokens", `Int compaction.before_tokens);
        ("compaction_after_tokens", `Int compaction.after_tokens);
        ("compaction_saved_tokens", `Int compaction.saved_tokens);
        ("compaction_trigger",
          match compaction.trigger with
          | Some reason -> `String reason
          | None -> `Null);
        ("turn_mode", `String (turn_mode_to_string turn_mode));
        ( "scheduled_autonomous_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (scheduled_autonomous_cycle_outcome_to_string outcome)
          | None -> `Null );
        ( "proactive_outcome",
          match scheduled_autonomous_outcome with
          | Some outcome ->
              `String (scheduled_autonomous_cycle_outcome_to_string outcome)
          | None -> `Null );
        ("tool_call_count", `Int result.tool_calls_made);
        ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
        ( "action_source",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.action_source_of_execution_result execution
              |> Keeper_deliberation.action_source_to_json
          | None -> `Null );
        ( "deliberation_execution",
          match deliberation_execution with
          | Some execution ->
              Keeper_deliberation.execution_result_to_json execution
          | None -> `Null );
        ("cascade",
         match result.cascade_observation with
         | Some observation -> Oas_worker.cascade_observation_to_json observation
         | None -> `Null);
        ("snapshot_source", `String snapshot_source);
        ("memory_check", memory_check_default_json ());
        ("handoff_performed",
         `Bool
           (match handoff_json with
            | Some (`Assoc fields) ->
                Safe_ops.json_bool ~default:false "performed" (`Assoc fields)
            | _ -> false));
        ("handoff",
         match handoff_json with
         | Some value -> value
         | None -> `Assoc [ ("performed", `Bool false) ]);
        ( "trace_ref",
          match result.trace_ref with
          | Some trace_ref ->
              Oas.Raw_trace.run_ref_to_yojson trace_ref
          | None -> `Null );
        ( "run_validation",
          match result.run_validation with
          | Some validation ->
              Oas.Raw_trace.run_validation_to_yojson validation
          | None -> `Null );
        ("cdal_proof",
         match result.proof with
         | Some p ->
           `Assoc [
             ("run_id", `String p.Oas.Cdal_proof.run_id);
             ("effective_mode",
              Oas.Execution_mode.to_yojson p.effective_execution_mode);
             ("result_status",
              Oas.Cdal_proof.result_status_to_yojson p.result_status);
             ("violation_count",
              `Int (cdal_violation_ref_count p));
             ("raw_evidence_ref_count",
              `Int (cdal_raw_evidence_ref_count p));
             ("tool_trace_count",
              `Int (List.length p.tool_trace_refs));
             ("mode_source", `String p.mode_decision_source);
           ]
         | None -> `Null);
        ("inference_telemetry",
         match result.inference_telemetry with
         | Some t ->
           Oas.Types.inference_telemetry_to_yojson t
         | None -> `Null);
      ]
  in
  Dated_jsonl.append metrics_store snapshot;
  (* #9943: a compaction trigger that produced no token reduction
     is invisible in [masc_keeper_compactions_total] (which counts
     trigger fires).  Emit a dedicated counter here so dashboards
     can alert on the noop rate — production audit (2026-04-24)
     showed 956/972 = 98.4% of compaction snapshots were silent
     noops.  Emit only when a trigger fired and before/after match
     at a non-zero token count; the [trigger] label uses the
     human-readable reason already present in the snapshot. *)
  (match compaction.trigger with
   | Some trigger
     when compaction.before_tokens > 0
       && compaction.before_tokens = compaction.after_tokens ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_compaction_noop
         ~labels:[ ("keeper", meta.name); ("trigger", trigger) ]
         ()
   | _ -> ())

let broadcast_lifecycle_events ~(name : string)
    ~(turn_generation : int)
    ~(compaction : Keeper_exec_context.compaction_event)
    ~(handoff_json : Yojson.Safe.t option) : unit =
  let now_ts = Time_compat.now () in
  (if compaction.applied then
     try
       Sse.broadcast
         (`Assoc
           [
             ("type", `String "keeper_compaction");
             ("name", `String name);
             ("generation", `Int turn_generation);
             ("before_tokens", `Int compaction.before_tokens);
             ("after_tokens", `Int compaction.after_tokens);
             ("saved_tokens", `Int compaction.saved_tokens);
             ( "trigger",
               match compaction.trigger with
               | Some reason -> `String reason
               | None ->
                   `String
                     (Keeper_exec_context.compaction_decision_to_string
                        compaction.decision) );
             ("ts_unix", `Float now_ts);
           ])
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Keeper.error "compaction SSE broadcast failed: %s"
           (Printexc.to_string exn));
  match handoff_json with
  | Some ((`Assoc _ as handoff)) ->
      let from_generation =
        Safe_ops.json_int ~default:turn_generation "from_generation" handoff
      in
      let to_generation =
        Safe_ops.json_int ~default:(from_generation + 1) "to_generation" handoff
      in
      let to_model = Safe_ops.json_string ~default:"" "to_model" handoff in
      (try
         Sse.broadcast
           (`Assoc
             [
               ("type", `String "keeper_handoff");
               ("name", `String name);
               ("from_generation", `Int from_generation);
               ("to_generation", `Int to_generation);
               ("from_model", `Null);
               ("to_model",
                if String.trim to_model = "" then `Null else `String to_model);
               ("ts_unix", `Float now_ts);
             ])
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Keeper.error "handoff SSE broadcast failed: %s"
            (Printexc.to_string exn));
  | _ -> ()

let update_metrics_from_failure (meta : keeper_meta) ~(latency_ms : int)
    ~(observation : Keeper_world_observation.world_observation)
    ~(reason : string) ?(is_transient = false) ?social_state
    ?social_transition_reason
    ?sdk_error
    () : keeper_meta =
  ignore is_transient; (* Param retained for caller compatibility; no longer
                          used internally after zombie-fix #5594. *)
  let now_ts = Time_compat.now () in
  let is_scheduled_autonomous_cycle =
    is_scheduled_autonomous_cycle_of_observation observation
  in
  let public_reason =
    match sdk_error with
    | Some err -> (
        match Oas_worker_named.classify_masc_internal_error err with
        | Some (Oas_worker_named.Resumable_cli_session { detail; _ }) ->
            let trimmed = String.trim detail in
            if trimmed = "" then reason else trimmed
        | Some
            (Oas_worker_named.Oas_timeout_budget
               {
                 budget_sec;
                 keeper_turn_timeout_sec;
                 estimated_input_tokens;
                 source;
               }) ->
            Printf.sprintf
              "OAS budget timeout after %.1fs (%s, estimated input %d tokens, keeper hard cap %.1fs)"
              budget_sec source estimated_input_tokens keeper_turn_timeout_sec
        | _ -> reason)
    | None -> reason
  in
  let failure_counts_for_proactive_backoff =
    is_scheduled_autonomous_cycle
    &&
    match sdk_error with
    | Some err -> (
        match Oas_worker_named.classify_masc_internal_error err with
        | Some
            (Oas_worker_named.Oas_timeout_budget _
            | Oas_worker_named.Turn_timeout _
            | Oas_worker_named.Admission_queue_timeout _
            | Oas_worker_named.Admission_queue_rejected _
            | Oas_worker_named.Resumable_cli_session _
            | Oas_worker_named.No_tool_capable_provider _) ->
            true
        | Some _ | None -> false)
    | None -> false
  in
  (* #10474: emit Prometheus counters for no_tool_provider and proactive
     cycle outcomes so Grafana can surface fleet-wide health ratios. *)
  (match sdk_error with
   | Some err ->
       (match Oas_worker_named.classify_masc_internal_error err with
        | Some (Oas_worker_named.No_tool_capable_provider
	                  { cascade_name; _ }) ->
            let cascade_name =
              Oas_worker_named.cascade_name_to_string cascade_name
            in
            Prometheus.inc_counter
              Prometheus.metric_keeper_no_tool_provider
              ~labels:
                [ ("keeper", meta.name)
                ; ("cascade", cascade_name)
                ]
              ()
        | _ -> ())
   | None -> ());
  if is_scheduled_autonomous_cycle then
    Prometheus.inc_counter Prometheus.metric_keeper_proactive_outcome
      ~labels:[ ("keeper", meta.name); ("outcome", "error") ]
      ();
  let preview =
    let trimmed = String.trim public_reason in
    if trimmed = "" then "keeper cycle failed"
    else short_preview trimmed
  in
  {
    meta with
    updated_at = now_iso ();
    runtime = { meta.runtime with
      usage = { meta.runtime.usage with
        total_turns = meta.runtime.usage.total_turns + 1;
        last_turn_ts = now_ts;
        last_latency_ms = latency_ms;
      };
      proactive_rt = { meta.runtime.proactive_rt with
        count_total =
          meta.runtime.proactive_rt.count_total
          + (if is_scheduled_autonomous_cycle then 1 else 0);
        (* Always update last_ts on scheduled_autonomous attempts,
           including transient errors. Without this, transient errors
           (e.g. llama-server down) leave last_ts stale, causing
           cooldown_elapsed=false permanently → scheduled turns never
           resume. last_ts tracks attempts, not successes.
           Root cause of keeper zombie state: #5594. *)
        last_ts =
          if is_scheduled_autonomous_cycle then now_ts
          else meta.runtime.proactive_rt.last_ts;
        last_outcome =
          if is_scheduled_autonomous_cycle then Proactive_error
          else meta.runtime.proactive_rt.last_outcome;
        last_reason =
          if is_scheduled_autonomous_cycle
          then "unified:error:" ^ String.trim public_reason
          else meta.runtime.proactive_rt.last_reason;
        last_preview =
          if is_scheduled_autonomous_cycle then preview
          else meta.runtime.proactive_rt.last_preview;
        consecutive_noop_count =
          (if failure_counts_for_proactive_backoff then
             meta.runtime.proactive_rt.consecutive_noop_count + 1
           else meta.runtime.proactive_rt.consecutive_noop_count);
      };
      last_speech_act =
        (match social_state with
         | Some (state : Social.social_state) ->
             Social.speech_act_to_string state.speech_act
         | None -> meta.runtime.last_speech_act);
      last_social_transition_reason =
        (match social_transition_reason with
         | Some value -> String.trim value
         | None -> meta.runtime.last_social_transition_reason);
      last_active_desire =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.active_desire
         | None -> meta.runtime.last_active_desire);
      last_current_intention =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.current_intention
         | None -> meta.runtime.last_current_intention);
      last_blocker =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.blocker
         | None -> short_preview public_reason);
      last_blocker_class =
        (match sdk_error with
         | Some err ->
             Keeper_status_bridge.blocker_class_of_sdk_error err
         | None -> None);
      last_need =
        (match social_state with
         | Some (state : Social.social_state) ->
             Option.value ~default:"" state.need
         | None -> meta.runtime.last_need);
    };
  }
