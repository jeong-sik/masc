(** Dashboard_http_keeper_types — pure helpers extracted from
    Dashboard_http_keeper (2327 LoC godfile).

    See dashboard_http_keeper_types.mli for rationale. *)

let runtime_warning_ctx_ratio =
  Env_config_keeper.DashboardHealth.runtime_warning_ctx_ratio

let live_keeper_runtime_id_result (raw : string) :
    (string, [ `Unresolved of string ]) result =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then Error (`Unresolved raw) else Ok trimmed

let prompt_block_json key =
  let resolved = Prompt_registry.resolve_prompt key in
  `Assoc
    [
      ("key", `String key);
      ( "source",
        `String (Prompt_registry.prompt_source_to_string resolved.source) );
      ("text", `String resolved.effective);
    ]

let tokens_per_sec_json ~tokens ~latency_ms =
  if tokens <= 0 || latency_ms <= 0 then `Null
  else `Float ((float_of_int tokens *. 1000.0) /. float_of_int latency_ms)

let last_latency_ms_json latency_ms =
  if latency_ms <= 0 then `Null else `Int latency_ms

let terminal_reason_code_of_decision_json json =
  match Json_util.assoc_member_opt "terminal_reason" json with
  | Some (`Assoc _ as terminal_reason) ->
    Option.map Keeper_turn_terminal.code (Keeper_turn_terminal.of_json terminal_reason)
  | Some _ | None -> None

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

let nonempty_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let percentile_sorted_float (sorted : float array) (p : float) : float =
  let n = Array.length sorted in
  if n = 0 then 0.0
  else
    let rank = p /. 100.0 *. Float.of_int (n - 1) in
    let lo = int_of_float (floor rank) in
    let hi = min (lo + 1) (n - 1) in
    let frac = rank -. Float.of_int lo in
    sorted.(lo) *. (1.0 -. frac) +. sorted.(hi) *. frac

let keeper_decisions_dashboard_surface = "/api/v1/dashboard/keeper-decisions"

let k2_feed_limit limit = max 1 (min 200 limit)

let keeper_decisions_retention_json ~keeper_count =
  `Assoc
    [
      ("scope", `String "per_keeper_jsonl_tail");
      ("durable_store", `String ".masc/keepers/:name.decisions.jsonl");
      ("keeper_count", `Int keeper_count);
    ]
