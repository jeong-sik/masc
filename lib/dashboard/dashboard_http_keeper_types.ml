(** Dashboard_http_keeper_types — pure helpers extracted from
    Dashboard_http_keeper (2327 LoC godfile).

    See dashboard_http_keeper_types.mli for rationale. *)

let runtime_warning_ctx_ratio =
  Env_config_keeper.DashboardHealth.runtime_warning_ctx_ratio

(* RFC-0149 §3.3 — typed Result resolver for dashboard call sites.  The
   legacy live runtime-id facade + its silent-fallback carrier
   ([Keeper_runtime_profile.resolve_live]) were removed in the §3.3
   sunset closeout. *)
let live_keeper_runtime_id_result (raw : string) :
    (string, [ `Unresolved of string ]) result =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then Error (`Unresolved raw) else Ok trimmed

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

let terminal_reason_code_of_decision_json json =
  match Json_util.assoc_string_opt "terminal_reason_code" json with
  | Some _ as value -> value
  | None ->
    (match Json_util.assoc_member_opt "terminal_reason" json with
     | Some (`Assoc _ as terminal_reason) ->
       Json_util.assoc_string_opt "code" terminal_reason
     | _ -> None)

let execution_trust_source = "execution_receipt"
let execution_trust_producer = "keeper_agent_run.execution_receipt"
let execution_trust_dashboard_surface = "/api/v1/dashboard/execution-trust"
let execution_trust_freshness_slo_s = 900.0

(* Fixed cadence, not an env knob: the compute timeout remains operator-tunable
   via MASC_DASHBOARD_EXECUTION_TRUST_TIMEOUT_SEC. Keep the default timeout
   below this interval so Proactive_refresh can finish or fail one attempt
   before scheduling the next, while staying far inside the 900s freshness SLO. *)
let execution_trust_refresh_interval_s = 60.0

let max_ts_opt current candidate =
  match current with
  | Some existing when existing >= candidate -> current
  | Some _ | None -> Some candidate

let latest_receipt_ts_of_keeper_rows rows =
  rows
  |> List.fold_left
       (fun acc row ->
         match
           Option.value ~default:`Null (Json_util.assoc_member_opt "trust" row)
           |> (fun v -> Option.value ~default:`Null (Json_util.assoc_member_opt "last_receipt_at" v))
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
  let usage = Option.value ~default:`Null (Json_util.assoc_member_opt "usage" json) in
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

let memory_kind_for_log = function
  | Keeper_memory_policy.Progress -> "episode"
  | Keeper_memory_policy.Goal | Keeper_memory_policy.Decision -> "plan"
  | Keeper_memory_policy.Open_question | Keeper_memory_policy.Long_term -> "fact"

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
  else Masc_domain.iso8601_of_unix_seconds ts_unix

let k2_stable_id ~prefix ~keeper_name ~ts_unix ~raw =
  let ms = Int64.of_float (ts_unix *. 1000.0) in
  let hash = Digest.to_hex (Digest.string raw) in
  Printf.sprintf "%s-%s-%016Lx-%s"
    prefix keeper_name ms (String.sub hash 0 8)
