(** Dashboard HTTP keeper — keepers_dashboard_json rendering.

    Extracted from server_dashboard_http.ml. Contains the keeper dashboard
    rendering: per-keeper metrics series, 24h buckets, conversation history,
    memory bank, and diagnostic summaries. *)


open Dashboard_http_helpers
open Keeper_status_bridge

include Dashboard_http_keeper_detail

(** Context-ratio thresholds for keeper health scoring.
    These are distinct from Dashboard.ctx_* (compaction triggers) —
    health scoring penalizes keepers approaching context limits.
    Values sourced from [Env_config_keeper.DashboardHealth]. *)
let health_ctx_critical = Env_config_keeper.DashboardHealth.ctx_critical
let health_ctx_warn = Env_config_keeper.DashboardHealth.ctx_warn
let health_penalty_critical = Env_config_keeper.DashboardHealth.penalty_critical
let health_penalty_warn = Env_config_keeper.DashboardHealth.penalty_warn
let runtime_warning_ctx_ratio =
  Env_config_keeper.DashboardHealth.runtime_warning_ctx_ratio

let live_keeper_cascade_name (raw : string) =
  Keeper_cascade_profile.resolve_live raw

(** Compute keeper health score (0-100). Pure function.
    Inputs: restart_count, max_restarts, recent_crash_count,
            is_dead, context_ratio (0.0-1.0). *)
let compute_health_score
    ~restart_count ~max_restarts ~recent_crash_count
    ~is_dead ~context_ratio =
  if is_dead then 0
  else
    let budget_penalty =
      if max_restarts <= 0 then 0.0
      else
        let ratio = float_of_int restart_count /. float_of_int max_restarts in
        Float.min 1.0 ratio *. 40.0
    in
    let crash_penalty =
      Float.min 30.0 (float_of_int recent_crash_count *. 10.0)
    in
    let context_penalty =
      if context_ratio > health_ctx_critical then health_penalty_critical
      else if context_ratio > health_ctx_warn then health_penalty_warn
      else 0.0
    in
    let raw = 100.0 -. budget_penalty -. crash_penalty -. context_penalty in
    Int.max 0 (Int.min 100 (Float.to_int raw))

(** Outcomes rollup: aggregate successes / failures / validation for a keeper.

    Data sources (all already in-process, zero new schema):
    - [Keeper_transition_audit.recent_completed_turns] (50-entry ring) →
      turn outcomes classified after [mark_turn_finished].
    - [Keeper_transition_audit.recent_transitions] (50-entry ring) →
      compaction / handoff outcomes classified by [selected_event].
    - [registry_entry] crash_log / restart_count / turn_consecutive_failures
      → resilience counters.
    - [Dashboard_harness_health.read_recent_verdicts] → OAS verdict pass/fail
      scoped to this keeper by [agent_name].

    Conservation law (spec {!KeeperOutcomesConservation.tla}):
      successes.substantive_turns + failures.turn_failed + failures.gate_rejected
        = observed_turns
    holds by construction because all three turn buckets now come from the
    same completed-turn ring. *)
let compute_outcomes_rollup
    ~keeper_name
    ~agent_name
    ~recent_crash_count
    ~(registry_entry : Keeper_registry.registry_entry option) : Yojson.Safe.t =
  let succ_turns = ref 0 in
  let succ_compactions = ref 0 in
  let succ_handoffs = ref 0 in
  let fail_turn = ref 0 in
  let fail_gate_rejected = ref 0 in
  let fail_compaction = ref 0 in
  let fail_handoff = ref 0 in
  let completed_turns =
    Keeper_transition_audit.recent_completed_turns ~keeper_name ~limit:50
  in
  List.iter
    (fun (turn : Keeper_transition_audit.completed_turn_record) ->
      match turn.outcome with
      | Keeper_transition_audit.Turn_substantive -> incr succ_turns
      | Keeper_transition_audit.Turn_failed -> incr fail_turn
      | Keeper_transition_audit.Turn_gate_rejected -> incr fail_gate_rejected)
    completed_turns;
  let transitions =
    Keeper_transition_audit.recent_transitions ~keeper_name ~limit:50
  in
  List.iter (fun (tr : Keeper_transition_audit.transition_record) ->
    match tr.selected_event with
    | Keeper_state_machine.Compaction_completed _ -> incr succ_compactions
    | Compaction_failed _ -> incr fail_compaction
    | Handoff_completed _ -> incr succ_handoffs
    | Handoff_failed _ -> incr fail_handoff
    | _ -> Log.Dashboard.debug "ignored transition event"
  ) transitions;
  let observed_turns = List.length completed_turns in
  let restarts, consecutive_fail =
    match registry_entry with
    | Some (e : Keeper_registry.registry_entry) ->
        e.restart_count, e.turn_consecutive_failures
    | None -> 0, 0
  in
  let keeper_verdicts =
    try
      Dashboard_harness_health.read_recent_verdicts_for_agents
        ~limit:50
        ~agent_names:[ keeper_name; agent_name ]
        ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> []
  in
  let pass_v = ref 0 in
  let fail_v = ref 0 in
  let unknown_v = ref 0 in
  let fail_reasons = Hashtbl.create 8 in
  List.iter (fun (v : Dashboard_harness_health.harness_verdict_item) ->
    match Eval_calibration.verdict_of_string (String.lowercase_ascii v.verdict) with
    | Some Anti_rationalization.Approve -> incr pass_v
    | Some (Anti_rationalization.Reject reason) ->
        incr fail_v;
        let r =
          match v.fallback_reason, String.trim reason with
          | Some fallback_reason, _ -> fallback_reason
          | None, "" -> "unspecified"
          | None, parsed_reason -> parsed_reason
        in
        let cur = Hashtbl.find_opt fail_reasons r |> Option.value ~default:0 in
        Hashtbl.replace fail_reasons r (cur + 1)
    | None -> incr unknown_v
  ) keeper_verdicts;
  let top_failure_reasons =
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) fail_reasons []
    |> List.sort (fun (left_reason, left_count) (right_reason, right_count) ->
         let count_cmp = compare right_count left_count in
         if count_cmp <> 0 then count_cmp
         else String.compare left_reason right_reason)
    |> List.filteri (fun i _ -> i < 3)
    |> List.map (fun (r, _) -> `String r)
  in
  let last_verdict_at =
    match keeper_verdicts with
    | [] -> `Null
    | v :: _ -> `Float v.timestamp
  in
  let cdal_bucket gate_name =
    match
      List.find_opt
        (fun (s : Dashboard_attribution.gate_summary) ->
          String.equal s.gate gate_name)
        (Dashboard_attribution.summary ())
    with
    | None -> `Null
    | Some s ->
      `Assoc [
        ("scope", `String "global");
        ("passed", `Int s.passed);
        ("policy_failed", `Int s.policy_failed);
        ("transition_blocked", `Int s.transition_blocked);
        ("partial_pass", `Int s.partial_pass);
        ("total", `Int s.total);
      ]
  in
  `Assoc [
    ("window", `String "transition_ring_last_50");
    ("observed_turns", `Int observed_turns);
    ("successes", `Assoc [
      ("substantive_turns", `Int !succ_turns);
      ("compactions_ok", `Int !succ_compactions);
      ("handoffs_ok", `Int !succ_handoffs);
    ]);
    ("failures", `Assoc [
      ("turn_failed", `Int !fail_turn);
      ("gate_rejected", `Int !fail_gate_rejected);
      ("compaction_failed", `Int !fail_compaction);
      ("handoff_failed", `Int !fail_handoff);
      ("crashes", `Int recent_crash_count);
      ("restarts", `Int restarts);
      ("consecutive_fail_current", `Int consecutive_fail);
    ]);
    ("validation", `Assoc [
      ("oas_verdicts", `Assoc [
        ("pass", `Int !pass_v);
        ("fail", `Int !fail_v);
        ("unknown", `Int !unknown_v);
        ("top_failure_reasons", `List top_failure_reasons);
      ]);
      (* cdal_gate: populate from Dashboard_attribution ring.
         Scope is global (CDAL attribution is gate-keyed, not per-keeper),
         but visibility in the per-keeper diagnostic is still useful — it
         confirms the verdict gate is live and surfaces recent outcomes.

         Two buckets are exposed so consumers can tell "strict-enforced"
         from "allowed through under advisory":
         - [cdal_gate]            → gate="cdal_verdict"           (strict)
         - [cdal_gate_advisory]   → gate="cdal_verdict_advisory"  (audit-only) *)
      ("cdal_gate", cdal_bucket Cdal_verdict_gate.strict_gate_label);
      ("cdal_gate_advisory",
        cdal_bucket Cdal_verdict_gate.advisory_gate_label);
      ("last_verdict_at", last_verdict_at);
    ]);
  ]

(** Estimate seconds until Dead based on current restart_count and
    exponential backoff schedule. Returns None if already dead or
    restart_count >= max_restarts. *)
let estimate_dead_eta_sec ~restart_count ~max_restarts =
  if max_restarts <= 0 || restart_count >= max_restarts then None
  else
    let total = ref 0.0 in
    for i = restart_count to max_restarts - 1 do
      total := !total +. Keeper_supervisor.backoff_delay i
    done;
    Some !total

let prompt_block_json key =
  let resolved = Prompt_registry.resolve_prompt key in
  `Assoc
    [
      ("key", `String key);
      ("source", `String resolved.source);
      ("text", `String resolved.effective);
    ]

let tokens_per_sec_json ~tokens ~latency_ms =
  if tokens <= 0 || latency_ms <= 0 then `Null
  else `Float ((float_of_int tokens *. 1000.0) /. float_of_int latency_ms)

let json_string_list_member key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
    items
    |> List.filter_map (function
         | `String value ->
           let trimmed = String.trim value in
           if trimmed = "" then None else Some trimmed
         | _ -> None)
  | _ -> []

let json_string_member_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let terminal_reason_code_of_decision_json json =
  match json_string_member_opt "terminal_reason_code" json with
  | Some _ as value -> value
  | None ->
    (match Yojson.Safe.Util.member "terminal_reason" json with
     | `Assoc _ as terminal_reason ->
       json_string_member_opt "code" terminal_reason
     | _ -> None)

let keeper_trust_json ?(include_receipt = false)
    (config : Coord.config) (meta : Keeper_types.keeper_meta) =
  let latest_receipt = Keeper_execution_receipt.latest_json config meta.name in
  let runtime_trust =
    Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
  in
  let sandbox_json =
    match latest_receipt with
    | Some receipt -> Yojson.Safe.Util.member "sandbox" receipt
    | None ->
      `Assoc
        [
          ("kind", `String (Keeper_types.sandbox_profile_to_string meta.sandbox_profile));
          ("sandbox_root", `String config.base_path);
          ("network_mode", `String (Keeper_types.network_mode_to_string meta.network_mode));
        ]
  in
  let approval_json =
    match latest_receipt with
    | Some receipt -> Yojson.Safe.Util.member "approval" receipt
    | None -> `Assoc [ ("profile", `Null); ("derived", `Bool false) ]
  in
  let cascade_json =
    match latest_receipt with
    | Some receipt -> Yojson.Safe.Util.member "cascade" receipt
    | None ->
      `Assoc
        [
          ("name", `String meta.cascade_name);
          ("selected_model", `Null);
          ("attempt_count", `Int 0);
          ("fallback_applied", `Bool false);
          ("outcome", `String "not_observed");
        ]
  in
  let requested_tools =
    match latest_receipt with
    | Some receipt -> json_string_list_member "requested_tools" receipt
    | None -> []
  in
  let required_tools, missing_required_tools =
    match latest_receipt with
    | Some receipt ->
        let surface = Yojson.Safe.Util.member "tool_surface" receipt in
        ( json_string_list_member "required_tools" surface,
          json_string_list_member "missing_required_tools" surface )
    | None -> [], []
  in
  let tools_used =
    match latest_receipt with
    | Some receipt -> json_string_list_member "tools_used" receipt
    | None -> []
  in
  let unexpected_tools =
    match latest_receipt with
    | Some receipt -> json_string_list_member "unexpected_tools" receipt
    | None -> []
  in
  `Assoc
    [
      ( "last_outcome",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "outcome" receipt
        | None -> `String "not_run" );
      ( "terminal_reason_code",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "terminal_reason_code" receipt
        | None -> `String "no_receipt" );
      ( "operator_disposition",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "operator_disposition" receipt
        | None -> `String "not_run" );
      ( "operator_disposition_reason",
        match latest_receipt with
        | Some receipt ->
            Yojson.Safe.Util.member "operator_disposition_reason" receipt
        | None -> `String "no_receipt" );
      ( "tool_contract_result",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "tool_contract_result" receipt
        | None -> `String "unknown" );
      ("requested_tool_count", `Int (List.length requested_tools));
      ( "required_tools",
        `List (List.map (fun value -> `String value) required_tools) );
      ( "missing_required_tools",
        `List (List.map (fun value -> `String value) missing_required_tools) );
      ("tools_used", `List (List.map (fun value -> `String value) tools_used));
      ( "unexpected_tools",
        `List (List.map (fun value -> `String value) unexpected_tools) );
      ("sandbox", sandbox_json);
      ("approval", approval_json);
      ("cascade", cascade_json);
      ("disposition", Yojson.Safe.Util.member "disposition" runtime_trust);
      ( "disposition_reason",
        Yojson.Safe.Util.member "disposition_reason" runtime_trust );
      ("needs_attention", Yojson.Safe.Util.member "needs_attention" runtime_trust);
      ("attention_reason", Yojson.Safe.Util.member "attention_reason" runtime_trust);
      ("next_human_action", Yojson.Safe.Util.member "next_human_action" runtime_trust);
      ("approval_state", Yojson.Safe.Util.member "approval" runtime_trust);
      ("execution_summary", Yojson.Safe.Util.member "execution" runtime_trust);
      ( "latest_terminal_reason",
        Yojson.Safe.Util.member "latest_terminal_reason" runtime_trust );
      ( "latest_next_action",
        Yojson.Safe.Util.member "latest_next_action" runtime_trust );
      ("latest_causal_event", Yojson.Safe.Util.member "latest_causal_event" runtime_trust);
      ( "last_receipt_at",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "ended_at" receipt
        | None -> `Null );
      ( "last_error",
        match latest_receipt with
        | Some receipt -> Yojson.Safe.Util.member "error" receipt
        | None -> `Null );
      ( "last_receipt",
        if include_receipt then
          match latest_receipt with
          | Some receipt -> receipt
          | None -> `Null
        else
          `Null );
    ]

let execution_trust_source = "execution_receipt"
let execution_trust_producer = "keeper_agent_run.execution_receipt"
let execution_trust_dashboard_surface = "/api/v1/dashboard/execution-trust"
let execution_trust_freshness_slo_s = 900.0

let execution_receipt_dir config keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat (Coord.masc_root_dir config) "keepers")
       keeper_name)
    "execution-receipts"

let execution_receipt_store_pattern config =
  Filename.concat
    (Filename.concat (Coord.masc_root_dir config) "keepers")
    "*/execution-receipts"

let count_execution_receipt_entries config keeper_names =
  keeper_names
  |> List.fold_left
       (fun acc keeper_name ->
         let dir = execution_receipt_dir config keeper_name in
         if not (Sys.file_exists dir) then acc
         else
           acc
           +
           (match Dated_jsonl.create ~base_dir:dir () with
            | store -> Dated_jsonl.count_entries store
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
              Log.Dashboard.warn
                "execution_trust receipt count failed for %s: %s"
                dir
                (Printexc.to_string exn);
              0))
       0

let max_ts_opt current candidate =
  match current with
  | Some existing when existing >= candidate -> current
  | _ -> Some candidate

let latest_receipt_ts_of_keeper_rows rows =
  rows
  |> List.fold_left
       (fun acc row ->
         match
           Yojson.Safe.Util.member "trust" row
           |> Yojson.Safe.Util.member "last_receipt_at"
         with
         | `String iso -> (
             match Masc_domain.parse_iso8601_opt iso with
             | Some ts -> max_ts_opt acc ts
             | None -> acc)
         | _ -> acc)
       None

let freshness_fields ~now latest_ts =
  match latest_ts with
  | Some ts ->
    [
      ("latest_ts_unix", `Float ts);
      ("latest_ts_iso", `String (Masc_domain.iso8601_of_unix_seconds ts));
      ("latest_age_s", `Float (max 0.0 (now -. ts)));
    ]
  | None ->
    [
      ("latest_ts_unix", `Null);
      ("latest_ts_iso", `Null);
      ("latest_age_s", `Null);
    ]

let source_health_fields ~now ~exists ~entry_count ~latest_ts ?coverage_gap () =
  let health, stale_reason =
    match coverage_gap with
    | Some gap ->
      ( "coverage_gap",
        Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
    | None ->
      if not exists then ("missing", "store_missing")
      else if entry_count = 0 then ("empty", "no_entries")
      else
        match latest_ts with
        | None -> ("empty", "no_entries")
        | Some ts ->
          let latest_age_s = max 0.0 (now -. ts) in
          if latest_age_s > execution_trust_freshness_slo_s then
            ("stale", "freshness_slo_exceeded")
          else
            ("ok", "")
  in
  [
    ("health", `String health);
    ( "stale_reason",
      if stale_reason = "" then `Null else `String stale_reason );
  ]

let execution_receipt_coverage_gaps config =
  Telemetry_coverage_gap.read_recent
    ~masc_root:(Coord.masc_root_dir config)
    ~n:50
  |> List.filter (fun gap ->
       String.equal execution_trust_source
         (Safe_ops.json_string ~default:"" "source" gap))

let keeper_names (config : Coord.config) =
  Keeper_types.keeper_names config

let keeper_count (config : Coord.config) : int =
  List.length (keeper_names config)

let running_keeper_count (config : Coord.config) : int =
  keeper_names config
  |> List.fold_left
       (fun count name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta) when runtime_keepalive_running config meta -> count + 1
         | _ -> count)
       0

let keepers_dashboard_json ?(compact = false) (config : Coord.config) : Yojson.Safe.t =
  let include_goals = true in
  let history_fragment_filter_enabled =
    bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
  in
  let sandbox_preflight_json =
    Keeper_sandbox_runtime.docker_preflight ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Preflight ()) ()
    |> Option.map Keeper_sandbox_runtime.docker_preflight_to_yojson
  in
  let series_points = 120 in
  let names = keeper_names config in
  let now_ts = Time_compat.now () in
  let max_restarts =
    Runtime_params.get Governance_registry.keeper_supervisor_max_restarts
  in
  let keepers_dir =
    Filename.concat (Coord.masc_root_dir config) "keepers"
  in
  let shared_sp_events =
    try
      Keeper_crash_persistence.recent_sp_events
        ~keepers_dir ~max_entries:20
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        Log.Dashboard.warn
          "keeper dashboard recent_sp_events failed: %s"
          (Printexc.to_string exn);
        []
  in
  let accountability_summary =
    if compact || Keeper_decision_audit.decision_layer_level () < 3 then
      (fun ~keeper_name ~agent_name ->
        Keeper_exec_status_metrics.accountability_summary_json config
          ~keeper_name ~agent_name)
    else
      Keeper_exec_status_metrics.accountability_summary_lookup config
  in
  (* Parallel keeper I/O: each keeper's metadata + metrics reads run concurrently.
     Results are collected into a shared ref array, then filter_map'd. *)
  let results = Array.make (List.length names) None in
  Eio.Fiber.all
    (List.mapi (fun idx name -> fun () ->
      results.(idx) <- (
      match Keeper_types.read_meta config name with
      | Error _ | Ok None -> None
      | Ok (Some (m : Keeper_types.keeper_meta)) ->
          let agent = Keeper_exec_status.parse_agent_status config ~agent_name:m.agent_name in

          let created_ts =
            Coord_resilience.Time.parse_iso8601_opt m.created_at
            |> Option.value ~default:0.0
          in
          let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
          let last_turn_ago_s = if m.runtime.usage.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.runtime.usage.last_turn_ts in
          let last_handoff_ago_s =
            if m.runtime.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.runtime.last_handoff_ts
          in
          let last_compaction_ago_s =
            if m.runtime.compaction_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.compaction_rt.last_ts
          in
          let last_proactive_ago_s =
            if m.runtime.proactive_rt.last_ts <= 0.0 then 0.0 else now_ts -. m.runtime.proactive_rt.last_ts
          in
          let last_visible_proactive_ago_s =
            if m.runtime.proactive_rt.last_visible_ts <= 0.0 then 0.0
            else now_ts -. m.runtime.proactive_rt.last_visible_ts
          in
          (* C-3 fix: compute last_activity from the most recent activity timestamp
             to avoid showing misleading staleness when agent is actually active *)
          let last_activity_ts =
            List.fold_left max 0.0
              [ m.runtime.usage.last_turn_ts; m.runtime.proactive_rt.last_ts; m.runtime.last_handoff_ts;
                m.runtime.compaction_rt.last_ts; created_ts ]
          in
          let last_activity_ago_s =
            if last_activity_ts <= 0.0 then 0.0 else now_ts -. last_activity_ts
          in
          let trace_history_count = List.length m.runtime.trace_history in
          let active_model = Keeper_exec_status.active_model_of_meta m in
          let next_model_hint = Keeper_exec_status.next_model_hint_of_meta m in
          let effective_cascade_name = live_keeper_cascade_name m.cascade_name in
          let cascade_models =
            Cascade_runtime.models_of_cascade_name
              (Keeper_cascade_profile.Runtime_name effective_cascade_name)
          in
          let primary_model =
            match cascade_models with
            | model :: _ -> model
            | [] -> ""
          in
          let primary_model_norm = normalize_model_name primary_model in
          let last_compaction_saved_tokens =
            max 0 (m.runtime.compaction_rt.last_before_tokens - m.runtime.compaction_rt.last_after_tokens)
          in

          let metrics_store = Keeper_types.keeper_metrics_store config m.name in
          (* Cap metrics lines to avoid O(n) slowdown as keepers accumulate turns.
             series_points (120) suffices for the chart; 500 covers 24h summary.
             Previous value of 12000 caused 60K+ lines across 5 keepers. *)
          let metrics_cap = if compact then series_points else 500 in
          let metrics_window_max_bytes = if compact then 50000 else 200000 in
          let all_metrics_lines =
            let n = metrics_cap in
            let dated = Dated_jsonl.read_recent_lines metrics_store n in
            if dated <> [] then dated
            else
              let metrics_path = Keeper_types.keeper_metrics_path config m.name in
              Keeper_memory.read_file_tail_lines metrics_path
                ~max_bytes:metrics_window_max_bytes ~max_lines:n
          in
          let (metrics_24h, metrics_24h_summary) =
            if compact then (`Null, `Null)
            else keeper_metrics_24h_json ~metrics_lines:all_metrics_lines ~now_ts
          in
          let pr_action_metrics_lines =
            let action_store =
              Keeper_types.keeper_pr_action_metrics_store config m.name
            in
            Dated_jsonl.read_recent_lines action_store metrics_cap
          in
          let metrics_lines = all_metrics_lines in
          let parsed_metrics =
            List.filter_map (fun line ->
              try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None
            ) (metrics_lines @ pr_action_metrics_lines)
          in
          let last_metrics =
            List.find_opt metrics_row_has_context_snapshot
              (List.rev parsed_metrics)
          in
	          let (last_skill_primary, last_skill_secondary, last_skill_reason) =
	            let open Yojson.Safe.Util in
	            let rec find_latest = function
	              | [] -> (None, [], None)
	              | j :: tl ->
	                  (match Safe_ops.json_string_opt "skill_primary" j with
	                   | Some primary when String.trim primary <> "" ->
	                       let secondary =
	                         match j |> member "skill_secondary" with
	                         | `List xs ->
	                             xs
	                             |> List.filter_map (fun v ->
	                                    match v with
	                                    | `String s when String.trim s <> "" -> Some s
	                                    | _ -> None)
	                         | _ -> []
	                       in
	                       let reason = Safe_ops.json_string_opt "skill_reason" j in
	                       (Some primary, secondary, reason)
	                   | _ -> find_latest tl)
	            in
	            find_latest (List.rev parsed_metrics)
	          in


          let (metrics_series_items, metrics_window_summary, last_handoff_event, last_compaction_event) =
            compute_metrics_window
              ~parsed_metrics ~generation:m.runtime.generation ~compact ~series_points
              ~metrics_window_max_bytes ~primary_model_norm ~primary_model
          in
          let metrics_series = `List metrics_series_items in

          let models_resolved =
            `List (List.filter_map (fun label ->
              match String.index_opt label ':' with
              | Some i ->
                  let provider = String.sub label 0 i in
                  let model_id = String.sub label (i + 1) (String.length label - i - 1) in
                  Some (`Assoc [
                    ("provider", `String provider);
                    ("model_id", `String model_id);
                    ("max_context", `Int 0);
                  ])
              | None -> None
            ) cascade_models)
          in

          (* In compact mode (used by execution surface), skip heavy memory bank I/O.
             Full memory bank is only needed for individual keeper detail view. *)
          let (memory_bank_json, memory_recent_note) =
            if compact then
              (`Assoc [("total_files", `Int 0); ("skipped", `Bool true)], None)
            else
              let summary =
                Keeper_memory.read_keeper_memory_summary
                  config
                  ~name:m.name
                  ~max_bytes:120000
                  ~max_lines:200
                  ~recent_limit:4
              in
              let note = match summary.Keeper_memory.recent_notes with
                | row :: _ -> Some row.Keeper_memory.text
                | [] -> None
              in
              (Keeper_memory.memory_summary_to_json summary, note)
          in
          let history_path =
            Filename.concat
              (Filename.concat (Keeper_types.session_base_dir config) (Keeper_id.Trace_id.to_string m.runtime.trace_id))
              "history.jsonl"
          in
          let ( conversation_tail,
                k2k_recent,
                k2k_mentions,
                conversation_raw_count,
                conversation_fragment_count,
                conversation_fragment_filtered_count ) =
            keeper_history_summary_json
              ~all_keeper_names:names
              ~keeper_name:m.name
              ~history_path
              ~filter_fragments:history_fragment_filter_enabled
          in
          let conversation_tail_count =
            match conversation_tail with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let conversation_items =
            match conversation_tail with
            | `List xs -> xs
            | _ -> []
          in
          let recent_preview_for_role role_name =
            let role_name = String.lowercase_ascii role_name in
            conversation_items
            |> List.fold_left
                 (fun acc item ->
                   let role =
                     Safe_ops.json_string ~default:"" "role" item
                     |> String.lowercase_ascii
                     |> String.trim
                   in
                   if String.equal role role_name then
                     let preview =
                       Safe_ops.json_string ~default:"" "preview" item |> String.trim
                     in
                     if preview = "" then acc else Some preview
                   else
                     acc)
                 None
          in
          let k2k_count =
            match k2k_recent with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let keepalive_running = runtime_keepalive_running config m in
          let registry_entry =
            Keeper_registry.get ~base_path:config.base_path m.name in
          let phase =
            match registry_entry with
            | Some entry -> Some (Keeper_state_machine.phase_to_string entry.phase)
            | None -> None
          in
          let conditions_json =
            match registry_entry with
            | Some entry ->
                Keeper_state_machine.conditions_to_json entry.conditions
            | None -> `Null
          in
          let sandbox_last_error =
            match registry_entry with
            | Some entry -> entry.last_error
            | None -> None
          in
          let effective_sandbox_image =
            if m.sandbox_profile = Keeper_types.Docker
               || (m.sandbox_profile = Keeper_types.Local
                   && Env_config_keeper.DockerPlayground.enabled)
            then
              Some (
                match m.sandbox_image with
                | Some img when String.trim img <> "" -> img
                | _ -> Env_config_keeper.KeeperSandbox.docker_image ()
              )
            else None
          in
          let sandbox_preflight =
            match effective_sandbox_image, sandbox_preflight_json with
            | Some _, Some preflight -> Some preflight
            | _ -> None
          in
          (* reconcile_status removed with manual_reconcile blocker system. *)
          let runtime_blocker_fields =
            runtime_blocker_fields_json config m
          in
          let attention_fields =
            attention_fields_json config m
          in
          let runtime_contract =
            Keeper_runtime_contract.runtime_contract_json ~config m
          in
          let goal_progress =
            Yojson.Safe.Util.member "goal_progress" runtime_contract
          in
          let blocked_task_count =
            Safe_ops.json_int "blocked_task_count" ~default:0 runtime_contract
          in
          let approval_policy_effective =
            Yojson.Safe.Util.member "approval_policy_effective" runtime_contract
          in
          let sandbox_target =
            Safe_ops.json_string "sandbox_target" ~default:"unknown"
              runtime_contract
          in
          let supervisor_diagnostics, recent_crash_count =
            match registry_entry with
            | Some entry ->
                let crash_log =
                  List.map (fun (ts, reason) ->
                    `Assoc [("ts", `Float ts); ("reason", `String reason)]
                  ) entry.crash_log in
                let disk_crashes =
                  (try
                     Keeper_crash_persistence.recent_crashes
                       ~keepers_dir ~name:m.name ~max_entries:20
                   with
                   | Eio.Cancel.Cancelled _ as exn -> raise exn
                   | exn ->
                       Log.Dashboard.warn
                         "keeper dashboard recent_crashes failed for %s: %s"
                         m.name (Printexc.to_string exn);
                       []) in
                let combined_log = match disk_crashes with
                  | [] -> crash_log
                  | _ -> disk_crashes in
                let ctx_ratio =
                  match last_metrics with
                  | Some m -> Safe_ops.json_float "context_ratio" m
                  | None -> 0.0 in
                let health_score = compute_health_score
                  ~restart_count:entry.restart_count
                  ~max_restarts
                  ~recent_crash_count:(List.length combined_log)
                  ~is_dead:(Option.is_some entry.dead_since_ts)
                  ~context_ratio:ctx_ratio in
                (`Assoc [
                  ("restart_count", `Int entry.restart_count);
                  ("max_restarts", `Int max_restarts);
                  ("crash_log", `List combined_log);
                  ("last_failure_reason",
                    match entry.last_failure_reason with
                    | Some r -> `String (Keeper_registry.failure_reason_to_string r)
                    | None -> `Null);
                  ("dead_since",
                    match entry.dead_since_ts with
                    | Some ts -> `Float ts
                    | None -> `Null);
                  ("sp_events", `List shared_sp_events);
                  ("health_score", `Int health_score);
                  ("dead_eta_sec",
                    match estimate_dead_eta_sec
                      ~restart_count:entry.restart_count ~max_restarts with
                    | Some eta -> `Float eta
                    | None -> `Null);
                ], List.length combined_log)
            | None ->
                (`Assoc [
                  ("restart_count", `Int 0);
                  ("max_restarts", `Int max_restarts);
                  ("crash_log", `List []);
                  ("last_failure_reason", `Null);
                  ("dead_since", `Null);
                  ("sp_events", `List []);
                  ("health_score", `Int 100);
                  ("dead_eta_sec", `Null);
                ], 0)
          in
          let outcomes_json =
            compute_outcomes_rollup
              ~keeper_name:m.name
              ~agent_name:m.agent_name
              ~recent_crash_count
              ~registry_entry
          in

          let context =
            match last_metrics with
            | Some metrics ->
                `Assoc [
                  ("source", `String "metrics");
                  ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
                  ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
                  ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
                  ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
                ]
            | None ->
                (let effective_cascade_name = live_keeper_cascade_name m.cascade_name in
                 let effective_models =
                   Cascade_runtime.models_of_cascade_name
                     (Keeper_cascade_profile.Runtime_name effective_cascade_name)
                 in
                 let cfgs = Cascade_config.parse_model_strings effective_models in
                 match cfgs with
                 | [] when effective_models <> [] ->
                     `Assoc [("has_checkpoint", `Bool false)]
                 | _ ->
                     let primary_max_context =
                       Cascade_runtime.resolve_primary_max_context effective_models
                     in
                     let base_dir = Keeper_types.session_base_dir config in
                     let (_session, ctx_opt) =
                       Keeper_execution.load_context_from_checkpoint
                         ~max_checkpoint_messages:m.compaction.max_checkpoint_messages
                         ~trace_id:(Keeper_id.Trace_id.to_string m.runtime.trace_id)
                         ~primary_model_max_tokens:primary_max_context
                         ~base_dir
                     in
                     match ctx_opt with
                     | None -> `Assoc [("has_checkpoint", `Bool false)]
                     | Some c ->
                         `Assoc [
                           ("has_checkpoint", `Bool true);
                           ("source", `String "checkpoint");
                           ("context_ratio", `Float (Keeper_exec_context.context_ratio c));
                           ("context_tokens", `Int (Keeper_exec_context.token_count c));
                           ("context_max", `Int c.max_tokens);
                           ("message_count", `Int (Keeper_exec_context.message_count c));
                         ])
          in
	          let context_source =
	            match context with
	            | `Assoc fields ->
	                (match List.assoc_opt "source" fields with
	                 | Some s -> s
	                 | None -> `Null)
	            | _ -> `Null
	          in
	          let summary =
	            let compact_ratio_gate = m.compaction.ratio_gate in
	            let compact_message_gate = m.compaction.message_gate in
	            let compact_token_gate = m.compaction.token_gate in
              let trust_json =
                keeper_trust_json ~include_receipt:(not compact) config m
              in
              let recent_tool_names =
                match metrics_window_summary with
                | `Assoc fields -> (
                    match List.assoc_opt "top_tools" fields with
                    | Some (`List items) ->
                        items
                        |> List.filter_map (fun item ->
                               let tool =
                                 Safe_ops.json_string ~default:"" "tool" item |> String.trim
                               in
                               if tool = "" then None else Some tool)
                    | _ -> [])
                | _ -> []
              in
              let diagnostic =
	                Keeper_exec_status.keeper_diagnostic_json
	                  ~meta:m
	                  ~agent_status:agent
	                  ~keepalive_running
	                  ~history_items:conversation_items
	                  ~now_ts
	                |> Keeper_exec_status.augment_keeper_diagnostic_json
	                     ~meta:m
	                     ~keepalive_running
	                     ~keepalive_started_at:(runtime_keepalive_started_at config m)
                     ~now_ts
              in
              (* C0: Trust Observatory — raw signals side-by-side, no synthesis.
                 Reputation (overall_score), Thompson (alpha/beta), Stress (5 kinds).
                 Gated by MASC_DECISION_LAYER_LEVEL >= 3. *)
              let trust_observatory =
                if compact
                   || Keeper_decision_audit.decision_layer_level () < 3
                then `Null
                else
                  let reputation =
                    (try
                       let rep = Agent_reputation.compute_reputation config ~agent_name:m.agent_name in
                       Agent_reputation.reputation_to_json rep
                     with
                     | Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                       Log.Keeper.warn "trust_observatory reputation failed for %s: %s"
                         m.name (Printexc.to_string exn);
                       `Null)
                  in
                  let thompson =
                    let stats = Thompson_sampling.get_stats m.name in
                    `Assoc [
                      ("alpha", `Float stats.Thompson_sampling.alpha);
                      ("beta", `Float stats.Thompson_sampling.beta);
                      ("score", `Float (stats.alpha /. (stats.alpha +. stats.beta)));
                      ("selections", `Int stats.selections);
                      ("votes_up", `Int stats.total_votes_up);
                      ("votes_down", `Int stats.total_votes_down);
                    ]
                  in
                  let stress =
                    let all_events = Agent_stress.recent 50 in
                    let keeper_events = List.filter (fun ev ->
                      match ev with
                      | `Assoc fields ->
                        (match List.assoc_opt "agent_name" fields with
                         | Some (`String n) -> n = m.name || n = m.agent_name
                         | _ -> false)
                      | _ -> false
                    ) all_events in
                    `List (List.filteri (fun i _ -> i < 10) keeper_events)
                  in
                  let accountability =
                    accountability_summary ~keeper_name:m.name
                      ~agent_name:m.agent_name
                  in
                  `Assoc [
                    ("reputation", reputation);
                    ("accountability", accountability);
                    ("thompson", thompson);
                    ("stress_recent", stress);
                  ]
              in
              let runtime_trust =
                Keeper_runtime_trust_snapshot.snapshot_json
                  ~config ~meta:m
              in
              let detail_fields =
                if compact then []
                else [
                  ("last_metrics", match last_metrics with None -> `Null | Some j -> j);
                  ("metrics_series", metrics_series);
                  ("metrics_24h", metrics_24h);
                  ("memory_bank", memory_bank_json);
                  ("conversation_tail", conversation_tail);
                  ("k2k_recent", k2k_recent);
                  ("trust_observatory", trust_observatory);
                ]
              in
	            `Assoc ([
              ("name", `String m.name);
              ("pipeline_stage", `String
                (match registry_entry with
                 | Some entry ->
                   Keeper_exec_status.pipeline_stage_of_phase entry.phase
                 | None -> "offline"));
              ("runtime_class", `String "keeper");
              ("phase",
                match phase with
                | Some p -> `String p
                | None -> `Null);
              ("conditions", conditions_json);
              ("outcomes", outcomes_json);
            ] @ runtime_blocker_fields @ attention_fields @ [
              ("supervisor_diagnostics", supervisor_diagnostics);
              ("agent_name", `String m.agent_name);
              ( "keeper_id",
                match m.keeper_id with
                | Some keeper_id ->
                    `String (Keeper_id.Uid.to_string keeper_id)
                | None -> `Null );
              ("emoji", `String (let (e, _) = get_agent_identity m.name in e));
              ("koreanName", `String (let (_, k) = get_agent_identity m.name in k));
              ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id));
              ("generation", `Int m.runtime.generation);
              ( "current_task_id",
                Json_util.string_opt_to_json
                  (Option.map Keeper_id.Task_id.to_string m.current_task_id) );
              ("active_goal_ids", `List (List.map (fun goal_id -> `String goal_id) m.active_goal_ids));
              ("created_at", `String m.created_at);
              ("updated_at", `String m.updated_at);
              ("trace_history_count", `Int trace_history_count);
              ("active_goal_ids",
                `List (List.map (fun goal_id -> `String goal_id) m.active_goal_ids));
              ("goal", if include_goals then `String m.goal else `Null);
              ("short_goal", if include_goals then `String m.short_goal else `Null);
              ("mid_goal", if include_goals then `String m.mid_goal else `Null);
              ("long_goal", if include_goals then `String m.long_goal else `Null);
              ( "goal_horizons",
                if include_goals then
                  `Assoc [
                    ("short", `String m.short_goal);
                    ("mid", `String m.mid_goal);
                    ("long", `String m.long_goal);
                  ]
                else
                  `Null );
              ( "active_goals_tree",
                if (not compact) && include_goals && m.active_goal_ids <> [] then
                  let all_goals = Goal_store.list_goals config () in
                  let linked = List.filter (fun (g : Goal_store.goal) ->
                    List.mem g.id m.active_goal_ids) all_goals in
                  let tasks = Coord.get_tasks_safe config in
                  let forest =
                    Dashboard_goals.build_forest ~config ~goals:linked ~tasks
                  in
                  `Assoc [
                    ("count", `Int (List.length linked));
                    ("nodes", `List (List.map Dashboard_goals.tree_node_to_json forest));
                  ]
                else
                  `Null );
                ("will", if String.trim m.will = "" then `Null else `String m.will);              ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
              ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ("self_model", `Assoc [
                ("will", if String.trim m.will = "" then `Null else `String m.will);
                ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
                ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ]);
              ("models", `List (List.map (fun s -> `String s) cascade_models));
              ("models_resolved", models_resolved);
              ("primary_model", `String primary_model);
              ("active_model", `String active_model);
              ("next_model_hint", Json_util.string_opt_to_json next_model_hint);
              ("sandbox_profile",
                `String (Keeper_types.sandbox_profile_to_string m.sandbox_profile));
              ("sandbox_target", `String sandbox_target);
              ("sandbox_last_error",
                Json_util.string_opt_to_json sandbox_last_error);
              ("sandbox_preflight",
                Json_util.option_to_yojson Fun.id sandbox_preflight);
              ("effective_sandbox_image",
                Json_util.string_opt_to_json effective_sandbox_image);
              ("runtime_contract", runtime_contract);
              ("goal_progress", goal_progress);
              ("blocked_task_count", `Int blocked_task_count);
              ("approval_policy_effective", approval_policy_effective);
              ("runtime_trust", runtime_trust);
              ("paused", `Bool m.paused);
              ("keepalive_running", `Bool keepalive_running);
              ("autoboot_enabled", `Bool m.autoboot_enabled);
              ("auto_handoff", `Bool m.auto_handoff);
              ("handoff_threshold", `Float m.handoff_threshold);
              ("agent", agent);
              ( "status",
                `String
                  (Keeper_exec_status.keeper_surface_status ~agent_status:agent
                     ~diagnostic) );
              ("keeper_age_s", `Float keeper_age_s);
              ("uptime_hours", `Float (keeper_age_s /. 3600.0));
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_handoff_ago_s", `Float last_handoff_ago_s);
              ("last_compaction_ago_s", `Float last_compaction_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("last_visible_proactive_ago_s", `Float last_visible_proactive_ago_s);
              ("last_activity_ago_s", `Float last_activity_ago_s);
              ("handoff_count_total", `Int trace_history_count);
              ("total_turns", `Int m.runtime.usage.total_turns);
              ("total_input_tokens", `Int m.runtime.usage.total_input_tokens);
              ("total_output_tokens", `Int m.runtime.usage.total_output_tokens);
              ("total_tokens", `Int m.runtime.usage.total_tokens);
              ("total_cost_usd", `Float m.runtime.usage.total_cost_usd);
              ("last_model_used", `String m.runtime.usage.last_model_used);
              ("last_usage", `Assoc [
                ("input_tokens", `Int m.runtime.usage.last_input_tokens);
                ("output_tokens", `Int m.runtime.usage.last_output_tokens);
                ("total_tokens", `Int m.runtime.usage.last_total_tokens);
              ]);
              ("last_latency_ms", `Int m.runtime.usage.last_latency_ms);
              ("compaction_count", `Int m.runtime.compaction_rt.count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction.profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("autoboot_enabled", `Bool m.autoboot_enabled);
              ("proactive_enabled", `Bool m.proactive.enabled);
              ("proactive_idle_sec", `Int m.proactive.idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive.cooldown_sec);
              ("proactive_count_total", `Int m.runtime.proactive_rt.count_total);
              ("proactive_visible_count_total", `Int m.runtime.proactive_rt.visible_count_total);
              ("autonomous_turn_count", `Int m.runtime.autonomous_turn_count);
              ("autonomous_text_turn_count", `Int m.runtime.autonomous_text_turn_count);
              ("autonomous_tool_turn_count", `Int m.runtime.autonomous_tool_turn_count);
              ("board_reactive_turn_count", `Int m.runtime.board_reactive_turn_count);
              ("mention_reactive_turn_count", `Int m.runtime.mention_reactive_turn_count);
              ("noop_turn_count", `Int m.runtime.noop_turn_count);
              ("autonomous_action_count", `Int m.runtime.autonomous_action_count);
              ("last_autonomous_action_at",
                if String.trim m.runtime.last_autonomous_action_at = ""
                then `Null
                else `String m.runtime.last_autonomous_action_at);
              ("last_proactive_ts", `Float m.runtime.proactive_rt.last_ts);
              ("last_visible_proactive_ts", `Float m.runtime.proactive_rt.last_visible_ts);
              ( "last_proactive_outcome"
              , `String
                  (Keeper_types.proactive_cycle_outcome_to_string
                     m.runtime.proactive_rt.last_outcome) );
              ("last_proactive_reason",
                if String.trim m.runtime.proactive_rt.last_reason = ""
                then `Null
                else `String m.runtime.proactive_rt.last_reason);
	              ("last_proactive_preview",
	                if String.trim m.runtime.proactive_rt.last_preview = ""
	                then `Null
	                else `String m.runtime.proactive_rt.last_preview);
            ]
            @ Keeper_status_bridge.social_runtime_fields_json m
            @ [
	              ("skill_primary",
	                match last_skill_primary with
	                | Some s -> `String s
	                | None -> `Null);
	              ("skill_secondary",
	                `List (List.map (fun s -> `String s) last_skill_secondary));
	              ("skill_reason",
	                match last_skill_reason with
	                | Some s -> `String s
	                | None -> `Null);
              ("metrics_window", metrics_window_summary);
              ("metrics_24h_summary", metrics_24h_summary);
              ("memory_note_count",
                (match memory_bank_json with
                 | `Assoc fields ->
                     (match List.assoc_opt "total_notes" fields with
                      | Some n -> n
                      | None -> (match List.assoc_opt "total_files" fields with
                                 | Some n -> n
                                 | None -> `Int 0))
                 | _ -> `Int 0));
              ("memory_top_kind",
                (match memory_bank_json with
                 | `Assoc fields ->
                     (match List.assoc_opt "top_kind" fields with
                      | Some (`String _ as s) -> s
                      | _ -> `Null)
                 | _ -> `Null));
              ("memory_recent_note",
                match memory_recent_note with
                | Some text -> `String text
                | None -> `Null);
              ("recent_input_preview",
                match recent_preview_for_role "user" with
                | Some text -> `String text
                | None -> `Null);
              ("recent_output_preview",
                match recent_preview_for_role "assistant" with
                | Some text -> `String text
                | None -> `Null);
              ("recent_tool_names", `List (List.map (fun item -> `String item) recent_tool_names));
              ("conversation_tail_count", `Int conversation_tail_count);
              ("conversation_raw_count", `Int conversation_raw_count);
              ("conversation_fragment_count", `Int conversation_fragment_count);
              ("conversation_fragment_filtered_count", `Int conversation_fragment_filtered_count);
              ("conversation_fragment_filter_enabled", `Bool history_fragment_filter_enabled);
              ("k2k_count", `Int k2k_count);
              ("k2k_mentions", k2k_mentions);
              ("last_handoff_event", match last_handoff_event with Some j -> j | None -> `Null);
              ("last_compaction_event", match last_compaction_event with Some j -> j | None -> `Null);
              ("trust", trust_json);
              ("context", context);
              ("context_source", context_source);
              ("runtime_warning_ctx_ratio", `Float runtime_warning_ctx_ratio);
              (* Eval feed: latest verdict snapshot for this keeper (RFC-MASC-005) *)
              ("eval_latest",
                let base_path = config.base_path in
                let try_name agent_name =
                  Dashboard_eval_feed.read_latest ~base_path ~agent_name ~limit:1
                in
                let snapshots =
                  match try_name m.name with
                  | (_ :: _) as ss -> ss
                  | [] when m.agent_name <> m.name -> try_name m.agent_name
                  | other -> other
                in
                match snapshots with
                | s :: _ ->
                    `Assoc [
                      ("coverage", `Float s.verdict.coverage);
                      ("all_passed", `Bool s.verdict.all_passed);
                      ("layer_count", `Int (List.length s.verdict.layer_results));
                      ("passed_count",
                        `Int (List_util.count_if
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> lr.passed)
                          s.verdict.layer_results));
                      ("failed_count",
                        `Int (List_util.count_if
                          (fun (lr : Dashboard_eval_feed.layer_result_json) -> not lr.passed)
                          s.verdict.layer_results));
                      ("timestamp", `Float s.timestamp);
                      ("baseline_status", Json_util.string_opt_to_json s.baseline_status);
                    ]
                | [] -> `Null);
            ] @ detail_fields)
          in
          Some summary)
    ) names);
  let summaries = Array.to_list results |> List.filter_map Fun.id in
  (* H-9 fix: include recent alerts so BAD alerts are visible on dashboard *)
  let recent_alerts =
    let alerts_path = Keeper_types.keeper_alerts_path config in
    let lines =
      Keeper_memory.read_file_tail_lines alerts_path ~max_bytes:50000 ~max_lines:10
    in
    List.filter_map (fun line ->
      try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None
    ) lines
  in
  `Assoc [
    ("keepers", `List summaries);
    ("total", `Int (List.length summaries));
    ("recent_alerts", `List recent_alerts);
    ("alert_count", `Int (List.length recent_alerts));
  ]

let execution_trust_dashboard_json (config : Coord.config) : Yojson.Safe.t =
  let keepers =
    match keepers_dashboard_json ~compact:true config with
    | `Assoc fields -> (
        match List.assoc_opt "keepers" fields with
        | Some (`List rows) ->
          rows
          |> List.map (fun row ->
                 `Assoc
                   [
                     ("name", Yojson.Safe.Util.member "name" row);
                     ("agent_name", Yojson.Safe.Util.member "agent_name" row);
                     ("keeper_id", Yojson.Safe.Util.member "keeper_id" row);
                     ("phase", Yojson.Safe.Util.member "phase" row);
                     ( "pipeline_stage",
                       Yojson.Safe.Util.member "pipeline_stage" row );
                     ("status", Yojson.Safe.Util.member "status" row);
                     ("trace_id", Yojson.Safe.Util.member "trace_id" row);
                     ("generation", Yojson.Safe.Util.member "generation" row);
                     ("current_task_id", Yojson.Safe.Util.member "current_task_id" row);
                     ("active_goal_ids", Yojson.Safe.Util.member "active_goal_ids" row);
                     ("trust", Yojson.Safe.Util.member "trust" row);
                   ])
        | _ -> [])
    | _ -> []
  in
  let now = Unix.gettimeofday () in
  let keeper_names = keeper_names config in
  let keepers_root = Filename.concat (Coord.masc_root_dir config) "keepers" in
  let exists = Sys.file_exists keepers_root in
  let entry_count = count_execution_receipt_entries config keeper_names in
  let latest_ts = latest_receipt_ts_of_keeper_rows keepers in
  let coverage_gaps = execution_receipt_coverage_gaps config in
  let coverage_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
  `Assoc
    ([
      ("source", `String execution_trust_source);
      ("producer", `String execution_trust_producer);
      ("durable_store", `String (execution_receipt_store_pattern config));
      ("dashboard_surface", `String execution_trust_dashboard_surface);
      ("freshness_slo_s", `Float execution_trust_freshness_slo_s);
      ("entry_count", `Int entry_count);
      ("exists", `Bool exists);
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("keepers", `List keepers);
      ("total", `Int (List.length keepers));
      ("coverage_gaps", `List coverage_gaps);
      ("coverage_gap_count", `Int (List.length coverage_gaps));
    ]
    @ freshness_fields ~now latest_ts
    @ source_health_fields
        ~now ~exists ~entry_count ~latest_ts ?coverage_gap ())

let nonempty_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let parse_json_line_opt line =
  try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None

let recent_keeper_metric_jsons (config : Coord.config) name =
  let metrics_store = Keeper_types.keeper_metrics_store config name in
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 80 in
    if dated <> [] then dated
    else
      let metrics_path = Keeper_types.keeper_metrics_path config name in
      Keeper_memory.read_file_tail_lines metrics_path
        ~max_bytes:120000 ~max_lines:80
  in
  List.filter_map parse_json_line_opt lines

let metric_ts json =
  Safe_ops.json_float ~default:0.0 "ts_unix" json

let sort_by_latest_ts jsons =
  List.sort
    (fun left right -> Float.compare (metric_ts right) (metric_ts left))
    jsons

let string_member_nonempty key json =
  Option.bind (Safe_ops.json_string_opt key json) nonempty_string_opt

let int_member_fallback key json =
  let usage = Yojson.Safe.Util.member "usage" json in
  match Safe_ops.json_int_opt key usage with
  | Some value -> Some value
  | None -> Safe_ops.json_int_opt key json

let rec take_list n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take_list (n - 1) rest

let recent_token_spend_json metrics =
  metrics
  |> List.filter_map (fun json ->
         let input_tokens = int_member_fallback "input_tokens" json in
         let output_tokens = int_member_fallback "output_tokens" json in
         let total_tokens =
           match int_member_fallback "total_tokens" json with
           | Some value -> Some value
           | None -> (
               match input_tokens, output_tokens with
               | Some input, Some output -> Some (input + output)
               | _ -> None)
         in
         match input_tokens, output_tokens, total_tokens with
         | None, None, None -> None
         | _ ->
             Some
               (`Assoc
                  [
                    ("ts_unix", `Float (metric_ts json));
                    ("ts", Json_util.string_opt_to_json (string_member_nonempty "ts" json));
                    ("channel", Json_util.string_opt_to_json (string_member_nonempty "channel" json));
                    ("model", Json_util.string_opt_to_json (string_member_nonempty "model_used" json));
                    ("input_tokens", Json_util.int_opt_to_json input_tokens);
                    ("output_tokens", Json_util.int_opt_to_json output_tokens);
                    ("total_tokens", Json_util.int_opt_to_json total_tokens);
                  ]))
  |> sort_by_latest_ts
  |> take_list 5

let latest_tool_call_json name =
  Keeper_tool_call_log.read_recent ~keeper_name:name ~n:10 ()
  |> List.sort
       (fun left right ->
         Float.compare
           (Safe_ops.json_float ~default:0.0 "ts" right)
           (Safe_ops.json_float ~default:0.0 "ts" left))
  |> List.find_opt (fun json ->
         match string_member_nonempty "tool" json with
         | Some _ -> true
         | None -> false)
  |> Option.map (fun json ->
         `Assoc
           [
             ("ts_unix", Json_util.float_opt_to_json (Safe_ops.json_float_opt "ts" json));
             ("tool", Json_util.string_opt_to_json (string_member_nonempty "tool" json));
             ("success", Json_util.bool_opt_to_json (Safe_ops.json_bool_opt "success" json));
             ("semantic_outcome", Json_util.string_opt_to_json (string_member_nonempty "semantic_outcome" json));
             ("duration_ms", Json_util.float_opt_to_json (Safe_ops.json_float_opt "duration_ms" json));
           ])

let keeper_bdi_snapshot_json (config : Coord.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_types.read_meta config name with
  | Error msg ->
      (`Not_found, `Assoc [ ("error", `String msg) ])
  | Ok None ->
      (`Not_found,
       `Assoc [ ("error", `String (Printf.sprintf "keeper %S not found" name)) ])
  | Ok (Some (m : Keeper_types.keeper_meta)) ->
      let metrics = recent_keeper_metric_jsons config name in
      let latest_social =
        sort_by_latest_ts metrics
        |> List.find_opt (fun json ->
               Option.is_some (string_member_nonempty "belief_summary" json)
               || Option.is_some (string_member_nonempty "active_desire" json)
               || Option.is_some (string_member_nonempty "current_intention" json)
               || Option.is_some (string_member_nonempty "need" json))
      in
      let metric_field key =
        Option.bind latest_social (string_member_nonempty key)
      in
      let belief =
        match metric_field "belief_summary" with
        | Some value -> Some value
        | None -> (
            match nonempty_string_opt m.runtime.last_blocker with
            | Some blocker -> Some ("blocked: " ^ blocker)
            | None -> None)
      in
      let desire =
        match metric_field "active_desire" with
        | Some value -> Some value
        | None -> nonempty_string_opt m.runtime.last_active_desire
      in
      let intention =
        match metric_field "current_intention" with
        | Some value -> Some value
        | None -> nonempty_string_opt m.runtime.last_current_intention
      in
      let need =
        match metric_field "need" with
        | Some value -> Some value
        | None -> nonempty_string_opt m.runtime.last_need
      in
      (`OK,
       `Assoc
         [
           ("keeper", `String m.name);
           ("generated_at", `String (Masc_domain.now_iso ()));
           ("poll_interval_ms", `Int 5000);
           ("belief", Json_util.string_opt_to_json belief);
           ("desire", Json_util.string_opt_to_json desire);
           ("intention", Json_util.string_opt_to_json intention);
           ("need", Json_util.string_opt_to_json need);
           ("profile_will", Json_util.string_opt_to_json (nonempty_string_opt m.will));
           ("profile_needs", Json_util.string_opt_to_json (nonempty_string_opt m.needs));
           ("profile_desires", Json_util.string_opt_to_json (nonempty_string_opt m.desires));
           ("recent_token_spend", `List (recent_token_spend_json metrics));
           ("last_tool_call", Json_util.option_to_yojson Fun.id (latest_tool_call_json name));
           ("source", `String "keeper_meta+metrics_jsonl+tool_call_log");
         ])

(** Build a structured config JSON for a single keeper, grouped by category.
    Returns (http_status, json). *)
let keeper_config_json (config : Coord.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_types.read_meta config name with
  | Error msg ->
      (`Not_found, `Assoc [ ("error", `String msg) ])
  | Ok None ->
      (`Not_found,
       `Assoc [ ("error", `String (Printf.sprintf "keeper %S not found" name)) ])
  | Ok (Some (m : Keeper_types.keeper_meta)) ->
      (* bootstrap_runtime is called at server startup — skip here to
         avoid blocking the HTTP handler with Eio.Mutex + file I/O (#3335). *)
      let active_model = Keeper_exec_status.active_model_of_meta m in
      let active_model_label =
        let value = Keeper_exec_status.active_model_label_of_meta m |> String.trim in
        if value = "" then None else Some value
      in
      let last_model_used_label =
        if String.trim m.runtime.usage.last_model_used = "" then None
        else active_model_label
      in
      let defaults = Keeper_types_profile.load_keeper_profile_defaults m.name in
      let persona_extended =
        Keeper_types_profile.resolved_persona_name ~keeper_name:m.name defaults
        |> Keeper_types_profile.load_persona_extended
        |> Option.value ~default:""
      in
      let active_goals =
        List.filter_map
          (fun goal_id ->
             match Goal_store.get_goal config ~goal_id with
             | Some { Goal_store.id; title; horizon } ->
                 let horizon_str =
                   match horizon with
                   | Goal_store.Short -> "short"
                   | Goal_store.Mid -> "mid"
                   | Goal_store.Long -> "long"
                 in
                 Some (id, title, horizon_str)
               | None -> None)
          m.active_goal_ids
      in
      let active_goal_ids_json =
        `List (List.map (fun goal_id -> `String goal_id) m.active_goal_ids)
      in
      let active_goals_json =
        `List
          (List.map
             (fun (id, title, horizon) ->
                `Assoc [
                  ("id", `String id);
                  ("title", `String title);
                  ("horizon", `String horizon);
                ])
             active_goals)
      in
      let resolved_active_goal_ids =
        List.map (fun (id, _, _) -> id) active_goals
      in
      let missing_active_goal_ids =
        m.active_goal_ids
        |> List.filter (fun goal_id ->
               not (List.mem goal_id resolved_active_goal_ids))
      in
      let coordination =
        match coordination_surface_json m with
        | `Assoc fields ->
            `Assoc
              (fields
               @ [
                   ("active_goal_ids", active_goal_ids_json);
                   ("active_goals", active_goals_json);
                   ("active_goal_count", `Int (List.length m.active_goal_ids));
                   ( "missing_active_goal_ids",
                     `List
                       (List.map
                          (fun goal_id -> `String goal_id)
                          missing_active_goal_ids) );
                 ])
        | other -> other
      in
      let runtime_trust =
        Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta:m
      in
      let effective_system_prompt =
        Keeper_prompt.build_keeper_system_prompt
          ~goal:m.goal ~short_goal:m.short_goal ~mid_goal:m.mid_goal
          ~long_goal:m.long_goal ~will:m.will
          ~needs:m.needs ~desires:m.desires ~instructions:m.instructions
          ~persona_extended ~keeper_name:m.name
          ~allowed_orgs:(Option.value (Keeper_tool_policy.git_clone_allowed_orgs ()) ~default:[])
          ~denied_repos:(Option.value (Keeper_tool_policy.git_clone_denied_repos ()) ~default:[])
          ~active_goals
          ()
      in
      let prompt =
        `Assoc [
          ("goal", `String m.goal);
          ("short_goal", `String m.short_goal);
          ("mid_goal", `String m.mid_goal);
          ("long_goal", `String m.long_goal);
          ("will", `String m.will);
          ("needs", `String m.needs);
          ("desires", `String m.desires);
          ("instructions", `String m.instructions);
          ( "system_prompt_blocks",
            `Assoc
              [
                ("constitution", prompt_block_json Keeper_prompt_names.constitution);
                ("world", prompt_block_json Keeper_prompt_names.world);
                ("capabilities", prompt_block_json Keeper_prompt_names.capabilities);
              ] );
          ("effective_system_prompt", `String effective_system_prompt);
        ]
      in
      let effective_cascade_name = live_keeper_cascade_name m.cascade_name in
      let execution =
        `Assoc [
          ("selected_cascade_name", `String m.cascade_name);
          ( "selected_cascade_canonical",
            `String effective_cascade_name );
          ( "models",
            `List
              (List.map (fun s -> `String s)
                 (Cascade_runtime.models_of_cascade_name
                    (Keeper_cascade_profile.Runtime_name effective_cascade_name))) );
          ("active_model", `String active_model);
          ("active_model_label", Json_util.string_opt_to_json active_model_label);
          ("last_model_used_label", Json_util.string_opt_to_json last_model_used_label);
          ( "per_provider_timeout_sec",
            Json_util.float_opt_to_json m.per_provider_timeout_s );
          ( "per_provider_timeout_mode",
            `String
              (match m.per_provider_timeout_s with
               | Some _ -> "override"
               | None -> "turn_budget_heuristic") );
          ("verify", `Bool false);
        ]
      in
      let compaction =
        `Assoc [
          ("profile", `String m.compaction.profile);
          ("ratio_gate", `Float m.compaction.ratio_gate);
          ("message_gate", `Int m.compaction.message_gate);
          ("token_gate", `Int m.compaction.token_gate);
          ("cooldown_sec", `Int m.compaction.cooldown_sec);
        ]
      in
      let proactive =
        `Assoc [
          ("enabled", `Bool m.proactive.enabled);
          ("idle_sec", `Int m.proactive.idle_sec);
          ("cooldown_sec", `Int m.proactive.cooldown_sec);
        ]
      in
      let drift =
        let toml_defaults =
          Keeper_types_profile.load_keeper_profile_defaults name
        in
        drift_surface_json ~unknown_toml_keys:toml_defaults.unknown_toml_keys
      in
      let handoff =
        `Assoc [
          ("auto", `Bool m.auto_handoff);
          ("threshold", `Float m.handoff_threshold);
          ("cooldown_sec", `Int m.handoff_cooldown_sec);
        ]
      in
      let metrics =
        `Assoc [
          ("generation", `Int m.runtime.generation);
          ("total_turns", `Int m.runtime.usage.total_turns);
          ("total_input_tokens", `Int m.runtime.usage.total_input_tokens);
          ("total_output_tokens", `Int m.runtime.usage.total_output_tokens);
          ("total_tokens", `Int m.runtime.usage.total_tokens);
          ("total_cost_usd", `Float m.runtime.usage.total_cost_usd);
          ("last_model_used", `String m.runtime.usage.last_model_used);
          ("last_input_tokens", `Int m.runtime.usage.last_input_tokens);
          ("last_output_tokens", `Int m.runtime.usage.last_output_tokens);
          ("last_total_tokens", `Int m.runtime.usage.last_total_tokens);
          ("last_latency_ms", `Int m.runtime.usage.last_latency_ms);
          ( "last_total_tokens_per_sec",
            tokens_per_sec_json ~tokens:m.runtime.usage.last_total_tokens
              ~latency_ms:m.runtime.usage.last_latency_ms );
          ( "last_output_tokens_per_sec",
            tokens_per_sec_json ~tokens:m.runtime.usage.last_output_tokens
              ~latency_ms:m.runtime.usage.last_latency_ms );
          ("compaction_count", `Int m.runtime.compaction_rt.count);
        ]
      in
      let current_phase =
        Keeper_registry.get_phase ~base_path:config.base_path m.name
      in
      let pipeline_stage =
        match current_phase with
        | Some phase -> Keeper_exec_status.pipeline_stage_of_phase phase
        | None -> "offline"
      in
      let state_diagram =
        Keeper_state_machine.phase_to_mermaid
          ~current:(Option.value ~default:Keeper_state_machine.Offline current_phase)
      in
      let decision_pipeline_diagram =
        let phase = Option.value ~default:Keeper_state_machine.Offline current_phase in
        let stats = Thompson_sampling.get_stats m.agent_name in
        let tool_count = List.length (Keeper_exec_tools.keeper_allowed_tool_names m) in
        let recovery_floor_count =
          List.length (Keeper_tool_policy.failing_minimum_tool_names ())
        in
        let turn_outcome : [`Ok | `Failed] option =
          match Keeper_registry.get ~base_path:config.base_path m.name with
          | Some entry when entry.turn_consecutive_failures > 0 ->
            Some `Failed
          | Some _ -> Some `Ok
          | None -> None
        in
        Keeper_decision_audit.decision_pipeline_to_mermaid
          ?turn_outcome
          ~guard_penalty_total:stats.guard_penalties_total
          ~phase
          ~thompson_alpha:stats.alpha
          ~thompson_beta:stats.beta
          ~tool_count
          ~recovery_floor_count
          ()
      in
      let tools_access =
        let allowed = Keeper_exec_tools.keeper_allowed_tool_names m in
        let masc_tool_count =
          List.length (Keeper_exec_tools.keeper_masc_tool_names m)
        in
        `Assoc [
          ("tool_access", Keeper_types.tool_access_to_json m.tool_access);
          ("resolved_allowlist", `List (List.map (fun s -> `String s) allowed));
          ("tool_denylist", `List (List.map (fun s -> `String s) m.tool_denylist));
          ("active_masc_tool_count", `Int masc_tool_count);
          ("active_keeper_tool_count",
            `Int (List.length allowed - masc_tool_count));
          ("total_active", `Int (List.length allowed));
        ]
      in
      let sandbox_last_error =
        match Keeper_registry.get ~base_path:config.base_path m.name with
        | Some entry -> entry.last_error
        | None -> None
      in
      let effective_sandbox_image =
        if m.sandbox_profile = Keeper_types.Docker
           || (m.sandbox_profile = Keeper_types.Local
               && Env_config_keeper.DockerPlayground.enabled)
        then Some (Env_config_keeper.KeeperSandbox.docker_image ())
        else None
      in
      let sandbox_preflight_json =
        Keeper_sandbox_runtime.docker_preflight ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Preflight ()) ()
        |> Option.map Keeper_sandbox_runtime.docker_preflight_to_yojson
      in
      let sandbox_preflight =
        match effective_sandbox_image, sandbox_preflight_json with
        | Some _, Some preflight -> Some preflight
        | _ -> None
      in
      let private_workspace_root =
        Keeper_sandbox.host_root_abs_of_meta ~config m
      in
      let sandbox_environment =
        let string_or_null value =
          let trimmed = String.trim value in
          if trimmed = "" then `Null else `String trimmed
        in
        `Assoc [
          ("base_path", `String config.base_path);
          ("project_root",
            `String (Keeper_alerting_path.project_root_of_config config));
          ("docker_playground_enabled",
            `Bool Env_config_keeper.DockerPlayground.enabled);
          ("docker_container_name",
            string_or_null Env_config_keeper.DockerPlayground.container_name);
          ("container_playground_root",
            string_or_null
              Env_config_keeper.DockerPlayground.container_playground_root);
          ("hard_mode",
            `Bool (Env_config_keeper.KeeperSandbox.hard_mode ()));
          ("git_egress",
            `String
              (if Env_config_keeper.KeeperSandbox.hard_mode () then
                 "brokered_structured_tools"
               else if Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled () then
                 "docker_git_dispatch"
               else
                 "container_network_policy"));
          ("credential_fallbacks_disabled",
            `Bool (Env_config_keeper.KeeperSandbox.hard_mode ()));
          ("docker_image",
            match effective_sandbox_image with
            | Some img -> string_or_null img
            | None -> `Null);
          ("pids_limit", `Int (Env_config_keeper.KeeperSandbox.pids_limit ()));
          ("memory",
            string_or_null (Env_config_keeper.KeeperSandbox.memory ()));
          ("tmpfs_size",
            string_or_null (Env_config_keeper.KeeperSandbox.tmpfs_size ()));
          ("relax_fs",
            `Bool (Env_config_keeper.KeeperSandbox.relax_fs ()));
          ("seccomp_profile",
            string_or_null
              (Env_config_keeper.KeeperSandbox.seccomp_profile ()));
          ("require_rootless",
            `Bool (Env_config_keeper.KeeperSandbox.require_rootless ()));
          ("require_userns",
            `Bool (Env_config_keeper.KeeperSandbox.require_userns ()));
          ("preflight",
            Json_util.option_to_yojson Fun.id sandbox_preflight);
        ]
      in
      (`OK,
       `Assoc [
         ("name", `String m.name);
         ("active_goal_ids", active_goal_ids_json);
         ("sandbox_profile", `String (Keeper_types.sandbox_profile_to_string m.sandbox_profile));
         ("network_mode", `String (Keeper_types.network_mode_to_string m.network_mode));         ("sandbox_last_error", Json_util.string_opt_to_json sandbox_last_error);
         ("sandbox_preflight",
           Json_util.option_to_yojson Fun.id sandbox_preflight);
         ("effective_sandbox_image",
           Json_util.string_opt_to_json effective_sandbox_image);
         ("private_workspace_root", `String private_workspace_root);
         ("sandbox_environment", sandbox_environment);
         ("allowed_paths",
           `List (List.map (fun s -> `String s) m.allowed_paths));
         ("effective_allowed_paths",
           `List (List.map (fun s -> `String s)
             (Keeper_alerting_path.effective_allowed_paths ~meta:m)));
         ("pipeline_stage", `String pipeline_stage);
         ("state_diagram", `String state_diagram);
         ("decision_pipeline_diagram", `String decision_pipeline_diagram);
         ("prompt", prompt);
         ("execution", execution);
         ("compaction", compaction);
         ("proactive", proactive);
         ("drift", drift);
         ("auto_execution_session", auto_execution_session_surface_json ());
         ("handoff", handoff);
         ("tools", tools_access);
         ("hooks", Keeper_hooks_oas.hook_introspection_json ());
         ("runtime", runtime_surface_json config m);
         ("runtime_trust", runtime_trust);
         ("coordination", coordination);
         ("sources", source_provenance_json config m);
         ("metrics", metrics);
       ])

(** Per-keeper cost/latency aggregates for the O4 cost dashboard.

    Reads each keeper's metrics JSONL, extracts cost_usd / latency_ms /
    token fields, and returns per-keeper totals plus p50/p95 latency
    percentiles and a model-level cost breakdown.

    This closes the Phase-2 gap between per-model metrics (already in
    /api/v1/models/metrics) and per-agent spend (required by preview). *)
let percentile_sorted_float (sorted : float array) (p : float) : float =
  let n = Array.length sorted in
  if n = 0 then 0.0
  else
    let rank = p /. 100.0 *. Float.of_int (n - 1) in
    let lo = int_of_float (floor rank) in
    let hi = min (lo + 1) (n - 1) in
    let frac = rank -. Float.of_int lo in
    sorted.(lo) *. (1.0 -. frac) +. sorted.(hi) *. frac

let keeper_cost_metric_row_is_event (json : Yojson.Safe.t) : bool =
  let field_equals key expected =
    Safe_ops.json_string_opt key json
    |> Option.map (fun value ->
         String.equal
           (String.lowercase_ascii (String.trim value))
           expected)
    |> Option.value ~default:false
  in
  (* Heartbeat status rows carry cumulative runtime usage snapshots, not
     per-call spend samples.  Counting them here inflates dashboard cost. *)
  not
    (field_equals "channel" "heartbeat"
     || field_equals "work_kind" "status_tick"
     || field_equals "snapshot_source" "keeper_context_status")

let keeper_cost_aggregates_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ~(window_minutes : int)
  : Yojson.Safe.t =
  let now_ts = Unix.gettimeofday () in
  let window_sec = float_of_int window_minutes *. 60.0 in
  let start_ts = now_ts -. window_sec in
  let keeper_items =
    List.map (fun (m : Keeper_types.keeper_meta) ->
      let metrics_store = Keeper_types.keeper_metrics_store config m.name in
      let all_metrics_lines =
        let dated = Dated_jsonl.read_recent_lines metrics_store 500 in
        if dated <> [] then dated
        else
          let metrics_path = Keeper_types.keeper_metrics_path config m.name in
          Keeper_memory.read_file_tail_lines metrics_path
            ~max_bytes:200000 ~max_lines:500
      in
      let costs_rev = ref [] in
      let latencies_rev = ref [] in
      let input_tokens = ref 0 in
      let output_tokens = ref 0 in
      let total_tokens = ref 0 in
      let model_costs : (string, float) Hashtbl.t = Hashtbl.create 8 in
      let sample_count = ref 0 in
      List.iter (fun line ->
        try
          let j = Yojson.Safe.from_string line in
          let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
          if ts_unix >= start_ts then begin
            let cost =
              Safe_ops.json_float_opt "cost_usd" j
              |> Option.value ~default:0.0
            in
            let latency_ms = Safe_ops.json_int ~default:0 "latency_ms" j in
            let input_t =
              Safe_ops.json_int_opt "input_tokens" j
              |> Option.value ~default:0
            in
            let output_t =
              Safe_ops.json_int_opt "output_tokens" j
              |> Option.value ~default:0
            in
            let total_t =
              Safe_ops.json_int_opt "total_tokens" j
              |> Option.value ~default:0
            in
            let model_used =
              Safe_ops.json_string ~default:"" "model_used" j
            in
            let model_used_norm = normalize_model_name model_used in
            if
              keeper_cost_metric_row_is_event j
              && (cost > 0.0 || latency_ms > 0)
            then begin
              costs_rev := cost :: !costs_rev;
              latencies_rev := float_of_int latency_ms :: !latencies_rev;
              input_tokens := !input_tokens + input_t;
              output_tokens := !output_tokens + output_t;
              total_tokens := !total_tokens + total_t;
              let prev =
                Option.value ~default:0.0
                  (Hashtbl.find_opt model_costs model_used_norm)
              in
              Hashtbl.replace model_costs model_used_norm (prev +. cost);
              incr sample_count;
            end
          end
        with
        | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ()
      ) all_metrics_lines;
      let total_cost = List.fold_left ( +. ) 0.0 !costs_rev in
      let latency_arr =
        let arr = Array.of_list !latencies_rev in
        Array.sort Float.compare arr;
        arr
      in
      let p50_latency =
        if Array.length latency_arr = 0 then None
        else Some (percentile_sorted_float latency_arr 50.0)
      in
      let p95_latency =
        if Array.length latency_arr = 0 then None
        else Some (percentile_sorted_float latency_arr 95.0)
      in
      let model_breakdown_json =
        model_costs
        |> Hashtbl.to_seq
        |> List.of_seq
        |> List.sort (fun (_, ca) (_, cb) -> Float.compare cb ca)
        |> List.map (fun (model, cost) ->
             `Assoc [
               ("model", `String model);
               ("cost_usd", `Float cost);
             ])
      in
      `Assoc [
        ("keeper_name", `String m.name);
        ("total_cost_usd", `Float total_cost);
        ("total_input_tokens", `Int !input_tokens);
        ("total_output_tokens", `Int !output_tokens);
        ("total_tokens", `Int !total_tokens);
        ("p50_latency_ms", Json_util.float_opt_to_json p50_latency);
        ("p95_latency_ms", Json_util.float_opt_to_json p95_latency);
        ("sample_count", `Int !sample_count);
        ("model_breakdown", `List model_breakdown_json);
      ]
    ) keepers
  in
  `Assoc [
    ("keepers", `List keeper_items);
    ("window_minutes", `Int window_minutes);
    ("generated_at", `Float now_ts);
  ]

let k2_feed_limit limit = max 1 (min 200 limit)

(** Read per-keeper [.decisions.jsonl] files and return a unified,
    time-sorted stream of recent events (turn telemetry, tool_exec,
    memory_search, etc.).  Each event is normalized to a flat record so
    the dashboard can render a single chronology without knowing the
    original schema variants. *)
let keeper_decisions_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ?(limit = 200)
    ()
  : Yojson.Safe.t =
  let limit = k2_feed_limit limit in
  let per_keeper_limit = limit * 2 in
  let all_events =
    List.concat_map (fun (m : Keeper_types.keeper_meta) ->
      let path = Keeper_types.keeper_decision_log_path config m.name in
      if not (Fs_compat.file_exists path) then []
      else
        let lines =
          Keeper_memory.read_file_tail_lines path
            ~max_bytes:500_000 ~max_lines:per_keeper_limit
        in
        List.filter_map (fun line ->
          try
            let json = Yojson.Safe.from_string line in
            let ts =
              match Yojson.Safe.Util.member "ts_unix" json with
              | `Float f -> f
              | `Int i -> float_of_int i
              | _ -> 0.0
            in
            let event_type =
              match Yojson.Safe.Util.member "event" json with
              | `String s -> s
              | _ -> "turn"
            in
            let keeper_name =
              match Yojson.Safe.Util.member "keeper_name" json with
              | `String s -> s
              | _ -> m.name
            in
            Some (ts, json, event_type, keeper_name)
          with
          | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
        ) lines
    ) keepers
  in
  let sorted =
    List.sort (fun (ta, _, _, _) (tb, _, _, _) -> compare tb ta) all_events
  in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let top = take limit sorted in
  let items =
    List.map (fun (_ts, json, event_type, keeper_name) ->
      let m = Yojson.Safe.Util.member in
      let string_or_null key =
        match m key json with `String s -> `String s | _ -> `Null
      in
      let float_or_null key =
        match m key json with
        | `Float f -> `Float f
        | `Int i -> `Float (float_of_int i)
        | _ -> `Null
      in
      let int_or_null key =
        match m key json with
        | `Int i -> `Int i
        | `Float f -> `Int (int_of_float f)
        | _ -> `Null
      in
      let duration_ms =
        match float_or_null "duration_ms" with
        | `Null -> float_or_null "latency_ms"
        | value -> value
      in
      let terminal_reason_code =
        match terminal_reason_code_of_decision_json json with
        | Some value -> `String value
        | None -> `Null
      in
      `Assoc [
        ("ts_unix", float_or_null "ts_unix");
        ("keeper_name", `String keeper_name);
        ("event_type", `String event_type);
        ("outcome", string_or_null "outcome");
        ("terminal_reason_code", terminal_reason_code);
        ("model_used", string_or_null "model_used");
        ("latency_ms", float_or_null "latency_ms");
        ("cost_usd", float_or_null "cost_usd");
        ("input_tokens", int_or_null "input_tokens");
        ("output_tokens", int_or_null "output_tokens");
        ("stop_reason", string_or_null "stop_reason");
        ("error_category", string_or_null "error_category");
        ("tool", string_or_null "tool");
        ("duration_ms", duration_ms);
        ("match_count", int_or_null "match_count");
      ]
    ) top
  in
  `Assoc [
    ("events", `List items);
    ("limit", `Int limit);
    ("generated_at", `Float (Unix.gettimeofday ()));
  ]

let k2_iso8601_of_unix ts_unix =
  if ts_unix <= 0.0 then ""
  else
    let t = Unix.gmtime ts_unix in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
      t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let k2_stable_id ~prefix ~keeper_name ~ts_unix ~raw =
  let ms = Int64.of_float (ts_unix *. 1000.0) in
  let hash = Digest.to_hex (Digest.string raw) in
  Printf.sprintf "%s-%s-%016Lx-%s"
    prefix keeper_name ms (String.sub hash 0 8)

let memory_kind_for_log (kind : string) : string =
  match String.lowercase_ascii (String.trim kind) with
  | "progress" -> "episode"
  | "goal" | "next" | "decision" -> "plan"
  | _ -> "fact"

let keeper_decisions_log_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ?(limit = 200)
    ()
  : Yojson.Safe.t =
  let limit = k2_feed_limit limit in
  let per_keeper_limit = limit * 2 in
  let all_events =
    List.concat_map (fun (m : Keeper_types.keeper_meta) ->
      let path = Keeper_types.keeper_decision_log_path config m.name in
      if not (Fs_compat.file_exists path) then []
      else
        let lines =
          Keeper_memory.read_file_tail_lines path
            ~max_bytes:500_000 ~max_lines:per_keeper_limit
        in
        List.filter_map (fun line ->
          try
            let json = Yojson.Safe.from_string line in
            let str key =
              match Yojson.Safe.Util.member key json with
              | `String s -> s
              | _ -> ""
            in
            let ts_unix =
              match Yojson.Safe.Util.member "ts_unix" json with
              | `Float f -> f
              | `Int i -> float_of_int i
              | _ -> 0.0
            in
            let keeper_name =
              let raw = str "keeper_name" in
              if raw = "" then m.name else raw
            in
            let id =
              let raw = str "id" in
              if raw <> "" then raw
              else k2_stable_id ~prefix:"dec" ~keeper_name ~ts_unix ~raw:line
            in
            let ts =
              let raw = str "ts" in
              if raw <> "" then raw else k2_iso8601_of_unix ts_unix
            in
            let decision_type =
              let sa = str "speech_act" in
              if sa <> "" then sa
              else
                let outcome = str "outcome" in
                if outcome <> "" then outcome else "turn"
            in
            let terminal_reason_code =
              terminal_reason_code_of_decision_json json
            in
            let duration_ms =
              let number key =
                match Yojson.Safe.Util.member key json with
                | `Float value -> Some value
                | `Int value -> Some (float_of_int value)
                | _ -> None
              in
              match number "duration_ms" with
              | Some _ as value -> value
              | None -> number "latency_ms"
            in
            let belief_summary = str "belief_summary" in
            let current_intention = str "current_intention" in
            let blocker = str "blocker" in
            let channel = str "channel" in
            let summary_parts =
              List.filter (fun s -> s <> "")
                [ decision_type
                ; (if channel <> "" then "via " ^ channel else "")
                ; (match terminal_reason_code with
                   | Some code -> "reason: " ^ code
                   | None -> "")
                ; (if current_intention <> "" then "\xe2\x86\x92 " ^ current_intention else "")
                ; (if blocker <> "" then "blocked: " ^ blocker else "")
                ; (if belief_summary <> "" then belief_summary else "")
                ]
            in
            let summary = String.concat " \xc2\xb7 " summary_parts in
            let evidence_refs =
              let refs = json_string_list_member "evidence_refs" json in
              let refs =
                if refs <> [] then refs
                else json_string_list_member "raw_evidence_refs" json
              in
              List.map (fun value -> `String value) refs
            in
            Some (ts_unix, `Assoc [
              ("id", `String id);
              ("ts", `String ts);
              ("ts_unix", `Float ts_unix);
              ("keeper", `String keeper_name);
              ("decision_type", `String decision_type);
              ("summary", `String summary);
              ( "terminal_reason_code",
                match terminal_reason_code with
                | Some code -> `String code
                | None -> `Null );
              ( "duration_ms",
                match duration_ms with
                | Some value -> `Float value
                | None -> `Null );
              ("evidence_refs", `List evidence_refs);
            ])
          with
          | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
        ) lines
    ) keepers
  in
  let sorted =
    List.sort (fun (ta, _) (tb, _) -> compare tb ta) all_events
  in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let items = List.map snd (take limit sorted) in
  `Assoc [
    ("events", `List items);
    ("limit", `Int limit);
    ("generated_at", `Float (Unix.gettimeofday ()));
  ]

let keeper_memory_log_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ?(limit = 200)
    ()
  : Yojson.Safe.t =
  let limit = k2_feed_limit limit in
  let per_keeper_limit = limit * 2 in
  let all_entries =
    List.concat_map (fun (m : Keeper_types.keeper_meta) ->
      let path = Keeper_types.keeper_memory_bank_path config m.name in
      if not (Fs_compat.file_exists path) then []
      else
        let lines =
          Keeper_memory.read_file_tail_lines path
            ~max_bytes:500_000 ~max_lines:per_keeper_limit
        in
        List.filter_map (fun line ->
          match Keeper_memory.parse_memory_bank_row line with
          | None -> None
          | Some (row : Keeper_memory.keeper_memory_row_raw) ->
              let kind = memory_kind_for_log row.kind in
              let ts = k2_iso8601_of_unix row.ts_unix in
              let id =
                k2_stable_id ~prefix:"mem" ~keeper_name:m.name
                  ~ts_unix:row.ts_unix ~raw:line
              in
              Some (row.ts_unix, `Assoc [
                ("id", `String id);
                ("ts", `String ts);
                ("ts_unix", `Float row.ts_unix);
                ("keeper", `String m.name);
                ("kind", `String kind);
                ("summary", `String row.text);
              ])
        ) lines
    ) keepers
  in
  let sorted =
    List.sort (fun (ta, _) (tb, _) -> compare tb ta) all_entries
  in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let items = List.map snd (take limit sorted) in
  `Assoc [
    ("entries", `List items);
    ("limit", `Int limit);
    ("generated_at", `Float (Unix.gettimeofday ()));
  ]
