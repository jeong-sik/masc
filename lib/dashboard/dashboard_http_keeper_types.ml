(** Dashboard_http_keeper_types — pure helpers extracted from
    Dashboard_http_keeper (2327 LoC godfile).

    See dashboard_http_keeper_types.mli for rationale. *)

let health_ctx_critical = Env_config_keeper.DashboardHealth.ctx_critical
let health_ctx_warn = Env_config_keeper.DashboardHealth.ctx_warn
let health_penalty_critical = Env_config_keeper.DashboardHealth.penalty_critical
let health_penalty_warn = Env_config_keeper.DashboardHealth.penalty_warn
let runtime_warning_ctx_ratio =
  Env_config_keeper.DashboardHealth.runtime_warning_ctx_ratio

let live_keeper_cascade_name (raw : string) =
  Keeper_cascade_profile.resolve_live raw

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

let last_latency_ms_json latency_ms =
  if latency_ms <= 0 then `Null else `Int latency_ms

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

let execution_trust_source = "execution_receipt"
let execution_trust_producer = "keeper_agent_run.execution_receipt"
let execution_trust_dashboard_surface = "/api/v1/dashboard/execution-trust"
let execution_trust_freshness_slo_s = 900.0

let max_ts_opt current candidate =
  match current with
  | Some existing when existing >= candidate -> current
  | Some _ | None -> Some candidate

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
