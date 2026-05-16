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

let nonempty_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let parse_json_line_opt line =
  try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None

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
    match Safe_ops.json_string_opt key json with
    | Some value ->
      String.equal
        (String.lowercase_ascii (String.trim value))
        expected
    | None -> false
  in
  not
    (field_equals "channel" "heartbeat"
     || field_equals "work_kind" "status_tick"
     || field_equals "snapshot_source" "keeper_context_status")

let memory_kind_for_log (kind : string) : string =
  match String.lowercase_ascii (String.trim kind) with
  | "progress" -> "episode"
  | "goal" | "next" | "decision" -> "plan"
  | _ -> "fact"

let keeper_decisions_dashboard_surface = "/api/v1/dashboard/keeper-decisions"

let k2_feed_limit limit = max 1 (min 200 limit)

let keeper_decisions_retention_json ~per_keeper_limit ~keeper_count =
  `Assoc
    [
      ("scope", `String "per_keeper_jsonl_tail");
      ("durable_store", `String ".masc/keepers/:name.decisions.jsonl");
      ("per_keeper_tail_lines", `Int per_keeper_limit);
      ("keeper_count", `Int keeper_count);
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
