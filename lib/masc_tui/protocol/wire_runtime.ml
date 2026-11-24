open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let runtime_resolved_path = "/api/v1/runtime/resolved"
let runtime_config_raw_path = "/api/v1/runtime/config/raw"
let runtime_assignment_path = "/api/v1/runtime/config/assignment"
let runtime_routing_path = "/api/v1/runtime/config/routing"
let setup_inventory_path = "/api/v1/setup/inventory"
let setup_credential_path = "/api/v1/setup/credential"
let setup_accounts_login_path = "/api/v1/setup/accounts/login?auth_hints=1"

let setup_accounts_login_status_path ~login_id =
  "/api/v1/setup/accounts/login/" ^ percent_encode login_id

let setup_accounts_login_input_path ~login_id =
  "/api/v1/setup/accounts/login/" ^ percent_encode login_id ^ "/input"

let runtime_probe_path ?(force = false) () =
  Printf.sprintf "/api/v1/dashboard/runtime-probe?force=%b" force

let provider_usage_history_path ~days =
  Printf.sprintf "/api/v1/dashboard/provider-usage-history?days=%d" days

let keeper_costs_path ~window_minutes =
  Printf.sprintf "/api/v1/dashboard/keeper-costs?window=%d" (max 1 window_minutes)

let keeper_efficiency_path ?month () =
  match month with
  | None -> "/api/v1/keeper-efficiency"
  | Some m -> "/api/v1/keeper-efficiency?month=" ^ percent_encode m

let models_chart_window_minutes = 1440
let models_chart_bucket_minutes = 60

let models_metrics_path ~window_minutes ~bucket_minutes =
  Printf.sprintf "/api/v1/models/metrics?window=%d&bucket_min=%d"
    (max 1 window_minutes) (max 0 bucket_minutes)

let models_metrics_stream_path =
  Printf.sprintf "/api/v1/models/metrics/stream?window=%d&bucket_min=%d"
    models_chart_window_minutes models_chart_bucket_minutes

let runtime_metrics_path = "/api/v1/runtime/metrics"

let tool_series_path ~bucket ~since_hours =
  let b = match bucket with `Hour -> "hour" | `Day -> "day" in
  Printf.sprintf "/api/v1/tool-metrics/series?bucket=%s&since_hours=%d" b
    (max 1 since_hours)

let tool_series_filtered_path ~bucket ~since_hours ?tool () =
  let base = tool_series_path ~bucket ~since_hours in
  match tool with
  | Some t when not (String.equal (String.trim t) "") ->
      base ^ "&tool=" ^ percent_encode (String.trim t)
  | Some _ | None -> base

let dashboard_tools_path ?keeper () =
  match keeper with
  | None -> "/api/v1/dashboard/tools"
  | Some k -> "/api/v1/dashboard/tools?keeper=" ^ percent_encode k

let tool_quality_path ?n ?window_hours () =
  match (window_hours, n) with
  | Some h, (Some _ | None) when h > 0 ->
      Printf.sprintf "/api/v1/dashboard/tool-quality?window_hours=%d" h
  | (Some _ | None), Some count when count > 0 ->
      Printf.sprintf "/api/v1/dashboard/tool-quality?n=%d" count
  | Some _, Some _ | Some _, None | None, Some _ | None, None ->
      "/api/v1/dashboard/tool-quality?n=5000"

let keeper_waiting_inventory_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/waiting-inventory"
    (percent_encode (String.trim keeper))

let mcp_rpc_path = "/mcp"
let mcp_protocol_version = "2026-07-28"

let skills_path = "/api/v1/skills"

let connector_unbind_path ~connector =
  "/api/v1/gate/connector/unbind?name=" ^ percent_encode (String.trim connector)

let fusion_runs_path = "/api/v1/dashboard/fusion-runs"

let fusion_launch_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/fusion" (percent_encode keeper)

let exact_lane_runs_path ?lane ?(limit = 20) () =
  let params =
    [ Printf.sprintf "limit=%d" (max 1 limit) ]
    @ match lane with None -> [] | Some l -> [ "lane=" ^ percent_encode l ]
  in
  "/api/v1/dashboard/exact-lane-runs?" ^ String.concat "&" params

let connectors_path = "/api/v1/gate/connectors"

(* [handle_gate_connector_bind] reads the connector from the [name] query
   parameter and refuses a request without it. *)
let connector_bind_path ~connector =
  "/api/v1/gate/connector/bind?name=" ^ percent_encode (String.trim connector)
let browser_lane_path = "/api/v1/dashboard/browser-lane/clients"
let browser_lane_read_path = "/api/v1/dashboard/browser-lane/read"
let lane_addons_path = "/api/v1/lane-addons"
let lane_addon_attach_path = "/api/v1/lane-addons/attach"
let lane_addon_detach_path = "/api/v1/lane-addons/detach"
let lane_addon_actions_path = "/api/v1/lane-addons/actions"

let lane_addon_asks_path ?(include_resolved = false) () =
  if include_resolved then "/api/v1/lane-addons/asks?include_resolved=true"
  else "/api/v1/lane-addons/asks?include_resolved=false"

let lane_addon_ask_answer_path = "/api/v1/lane-addons/ask-answer"
let mcp_clients_path = "/api/v1/dashboard/clients"

type usage_window_kind =
  | Window_five_hour
  | Window_seven_day
  | Window_duration_minutes of int
  | Window_provider_label of string

type usage_window_role =
  | Role_gates_model_calls
  | Role_counts_other_use
  | Role_unclassified_limit

type usage_utilization =
  | Util_fraction of float
  | Util_percent of int
  | Util_usd of { used : float; limit : float option }
  | Util_credit_balance of {
      currency : string;
      total : float option;
      remaining : float;
    }
  | Util_credit_unlimited
  | Util_credit_retracted

type usage_window = {
  limit_id : string option;
  kind : usage_window_kind;
  role : usage_window_role;
  utilization : usage_utilization;
  resets_at_unix : float option;
  observed_at_unix : float;
}

type account_usage_state =
  | Account_not_reported_since_start
  | Account_reported_no_windows of { observed_at_unix : float; source : string }
  | Account_reported of usage_window list

type usage_provider_ref = {
  id : string;
  display_name : string;
}

type account_usage = {
  scope : string;
  scope_id : string;
  providers : usage_provider_ref list;
  state : account_usage_state;
  cost_state : Format_val.cost_state;
}

type provider_usage_windows = {
  since_unix : float;
  accounts : account_usage list;
}

let classify_utilization = function
  | Util_credit_balance { remaining; _ } ->
      if remaining <= 0.0 then Format_val.Exhausted_zero
      else Format_val.Amount remaining
  | Util_usd { used; limit } -> (
      match limit with
      | Some lim when used >= lim -> Format_val.Exhausted_zero
      | Some _ | None -> Format_val.Amount used)
  | Util_fraction _ | Util_percent _ | Util_credit_unlimited ->
      Format_val.Subscription_zero
  | Util_credit_retracted -> Format_val.Unreported

let has_active_subscription_window windows =
  List.exists
    (fun (w : usage_window) ->
      match w.utilization with
      | Util_credit_unlimited -> true
      | Util_fraction f -> f < 1.0
      | Util_percent p -> p < 100
      | Util_credit_balance _ | Util_usd _ | Util_credit_retracted -> false)
    windows

let classify_account_cost_state = function
  | Account_not_reported_since_start | Account_reported_no_windows _ ->
      Format_val.Unreported
  | Account_reported [] -> Format_val.Unreported
  | Account_reported windows -> (
      let credit_opt =
        List.find_map
          (fun (w : usage_window) ->
            match w.utilization with
            | Util_credit_balance _ | Util_usd _ ->
                Some (classify_utilization w.utilization)
            | Util_fraction _ | Util_percent _ | Util_credit_unlimited
            | Util_credit_retracted ->
                None)
          windows
      in
      match credit_opt with
      | Some Format_val.Exhausted_zero ->
          if has_active_subscription_window windows then
            (* A subscription account with an active quota window (e.g. Ollama
               Cloud weekly 7% used) plus $0 extra purchased credit is still a
               live subscription, NOT exhausted. *)
            Format_val.Subscription_zero
          else Format_val.Exhausted_zero
      | Some ((Format_val.Amount _ | Format_val.Subscription_zero | Format_val.Unreported) as c) ->
          c
      | None -> (
          let has_sub =
            List.exists
              (fun (w : usage_window) ->
                match w.utilization with
                | Util_fraction _ | Util_percent _ | Util_credit_unlimited ->
                    true
                | Util_credit_balance _ | Util_usd _ | Util_credit_retracted ->
                    false)
              windows
          in
          if has_sub then Format_val.Subscription_zero
          else Format_val.Unreported))

let decode_window_kind json =
  let* kind = required_nonblank_string json "kind" in
  match kind with
  | "five_hour" -> Ok Window_five_hour
  | "seven_day" -> Ok Window_seven_day
  | "duration_minutes" ->
      let* minutes = required_int_field json "minutes" in
      if minutes > 0 then Ok (Window_duration_minutes minutes)
      else Error (Printf.sprintf "usage window minutes must be > 0, got %d" minutes)
  | "provider_label" ->
      let* label = required_nonblank_string json "label" in
      Ok (Window_provider_label label)
  | other -> Error (Printf.sprintf "unknown usage window kind %S" other)

let decode_window_role json =
  let* role = required_nonblank_string json "role" in
  match role with
  | "gates_model_calls" -> Ok Role_gates_model_calls
  | "counts_other_use" -> Ok Role_counts_other_use
  | "unclassified_limit" -> Ok Role_unclassified_limit
  | other -> Error (Printf.sprintf "unknown usage window role %S" other)

let decode_utilization json =
  let* unit_word = required_nonblank_string json "unit" in
  match unit_word with
  | "fraction" ->
      let* value = required_finite_float json "value" in
      Ok (Util_fraction value)
  | "percent" ->
      let* value = required_int_field json "value" in
      Ok (Util_percent value)
  | "usd" ->
      let* used = required_nonnegative_float json "value" in
      let* limit = required_nullable_float_field json "limit" in
      let* () =
        match limit with
        | Some l when (not (Float.is_finite l)) || l <= 0.0 ->
            Error "invalid USD usage limit"
        | Some _ | None -> Ok ()
      in
      Ok (Util_usd { used; limit })
  | "credit_balance" ->
      let* currency = required_nonblank_string json "currency" in
      let* total = required_nullable_float_field json "total" in
      let* remaining = required_nonnegative_float json "remaining" in
      let* () =
        match total with
        | Some t when (not (Float.is_finite t)) || t < 0.0 || remaining > t ->
            Error "invalid credit_balance total or remaining"
        | Some _ | None -> Ok ()
      in
      Ok (Util_credit_balance { currency; total; remaining })
  | "credit_unlimited" -> Ok Util_credit_unlimited
  | "credit_retracted" -> Ok Util_credit_retracted
  | other -> Error (Printf.sprintf "unknown usage unit %S" other)

let decode_usage_window json =
  let* limit_id = required_nullable_string_field json "limit_id" in
  let* kind_obj = required_object_field json "window" in
  let* kind = decode_window_kind kind_obj in
  let* role = decode_window_role json in
  let* util_obj = required_object_field json "utilization" in
  let* utilization = decode_utilization util_obj in
  let* resets_at_unix = optional_finite_float json "resets_at" in
  let* observed_at_unix = required_finite_float json "observed_at" in
  Ok { limit_id; kind; role; utilization; resets_at_unix; observed_at_unix }

let decode_account_usage json =
  let* scope = required_nonblank_string json "scope" in
  let* scope_id = required_nonblank_string json "scope_id" in
  let* provider_items = required_list_field json "providers" in
  let* providers =
    decode_list "providers"
      (fun p ->
        let* id = required_nonblank_string p "id" in
        let* display_name = required_nonblank_string p "display_name" in
        Ok { id; display_name })
      provider_items
  in
  let* state_str = required_nonblank_string json "state" in
  let* window_items = required_list_field json "windows" in
  let* windows = decode_list "windows" decode_usage_window window_items in
  let* state =
    match (state_str, windows) with
    | "reported", _ :: _ -> Ok (Account_reported windows)
    | "reported", [] ->
        Error (Printf.sprintf "account %S is reported with no window" scope)
    | "not_reported_since_start", [] -> Ok Account_not_reported_since_start
    | "not_reported_since_start", _ :: _ ->
        Error
          (Printf.sprintf "account %S has windows but is not_reported_since_start"
             scope)
    | "reported_no_windows", [] ->
        let* observed_at_unix = required_finite_float json "observed_at" in
        let* source = required_nonblank_string json "source" in
        Ok (Account_reported_no_windows { observed_at_unix; source })
    | "reported_no_windows", _ :: _ ->
        Error
          (Printf.sprintf "account %S has windows under reported_no_windows" scope)
    | other, _ -> Error (Printf.sprintf "unknown usage state %S" other)
  in
  let cost_state = classify_account_cost_state state in
  Ok { scope; scope_id; providers; state; cost_state }

let decode_provider_usage_windows json =
  let* _, body = unwrap_v2_or_raw json in
  let* since_unix =
    required_finite_float body "provider_usage_windows_since"
  in
  let* items = required_list_field body "provider_usage_windows" in
  let* accounts = decode_list "provider_usage_windows" decode_account_usage items in
  Ok { since_unix; accounts }

type provider_usage_history_point = {
  scope_id : string;
  source : string;
  kind : string;
  limit_id : string option;
  observed_at_unix : float;
  resets_at_unix : float option;
  utilization : usage_utilization;
}

type provider_usage_no_window = {
  scope_id : string;
  observed_at_unix : float;
}

type provider_usage_history =
  | Usage_history_unavailable of string
  | Usage_history_ready of {
      days : int;
      generated_at_unix : float;
      unreadable_reports : int;
      reported_no_windows : provider_usage_no_window list;
      points : provider_usage_history_point list;
    }

let decode_history_no_window json =
  let* scope_id = required_nonblank_string json "scope_id" in
  let* observed_at_unix = required_finite_float json "observed_at" in
  Ok { scope_id; observed_at_unix }

let decode_history_point json =
  let* scope_id = required_nonblank_string json "scope_id" in
  let* source = required_nonblank_string json "source" in
  let* kind = required_nonblank_string json "kind" in
  let* limit_id = optional_nonblank_string json "limit_id" in
  let* observed_at_unix = required_finite_float json "observed_at" in
  let* resets_at_unix = optional_finite_float json "resets_at" in
  let* utilization = decode_utilization json in
  Ok
    {
      scope_id;
      source;
      kind;
      limit_id;
      observed_at_unix;
      resets_at_unix;
      utilization;
    }

let decode_provider_usage_history json =
  let* _, body = unwrap_v2_or_raw json in
  if has_field body "state" then
    let* st = required_nonblank_string body "state" in
    match st with
    | "unavailable" ->
        let* reason =
          match optional_nonblank_string body "reason" with
          | Ok (Some r) -> Ok r
          | Ok None -> Ok "unavailable"
          | Error _ as err -> err
        in
        Ok (Usage_history_unavailable reason)
    | other ->
        Error (Printf.sprintf "unknown provider-usage-history state %S" other)
  else
    let* days = required_nonnegative_int_field body "days" in
    let* generated_at_unix = required_finite_float body "generated_at" in
    let* unreadable_reports =
      int_field_or body "unreadable_reports" ~default:0
    in
    let* no_win_items = optional_list_field body "reported_no_windows" in
    let* reported_no_windows =
      decode_list "reported_no_windows" decode_history_no_window no_win_items
    in
    let* point_items = required_list_field body "points" in
    let* points = decode_list "points" decode_history_point point_items in
    Ok
      (Usage_history_ready
         {
           days;
           generated_at_unix;
           unreadable_reports;
           reported_no_windows;
           points;
         })

type keeper_cost_row = {
  keeper_name : string;
  sample_count : int;
  total_tokens : int Observed.t;
  total_cost_usd : float Observed.t;
  tokens_reported_samples : int;
  tokens_missing_samples : int;
  cost_reported_samples : int;
  cost_missing_samples : int;
}

type keeper_costs_window = {
  generated_at_unix : float;
  window_minutes : int;
  rows : keeper_cost_row list;
}

let decode_keeper_cost_row ~observed_at json =
  let* keeper_name = required_nonblank_string json "keeper_name" in
  let* sample_count = required_nonnegative_int_field json "sample_count" in
  let* total_tokens = observed_int ~observed_at json "total_tokens" in
  let* total_cost_usd = observed_float ~observed_at json "total_cost_usd" in
  let* tokens_reported_samples =
    required_nonnegative_int_field json "tokens_reported_samples"
  in
  let* tokens_unreported =
    required_nonnegative_int_field json "tokens_unreported_samples"
  in
  let* tokens_unread =
    required_nonnegative_int_field json "tokens_unread_samples"
  in
  let* cost_reported_samples =
    required_nonnegative_int_field json "cost_reported_samples"
  in
  let* cost_unreported =
    required_nonnegative_int_field json "cost_unreported_samples"
  in
  let* cost_unread =
    required_nonnegative_int_field json "cost_unread_samples"
  in
  Ok
    {
      keeper_name;
      sample_count;
      total_tokens;
      total_cost_usd;
      tokens_reported_samples;
      tokens_missing_samples = tokens_unreported + tokens_unread;
      cost_reported_samples;
      cost_missing_samples = cost_unreported + cost_unread;
    }

let decode_keeper_costs_window ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* generated_at_unix = required_finite_float body "generated_at" in
  let* window_minutes = required_nonnegative_int_field body "window_minutes" in
  let* items = required_list_field body "keepers" in
  let* rows = decode_list "keepers" (decode_keeper_cost_row ~observed_at) items in
  Ok { generated_at_unix; window_minutes; rows }

type keeper_efficiency_row = {
  keeper : string;
  turns : int;
  input_tokens : int;
  cache_read_tokens : int Observed.t;
  cache_creation_tokens : int Observed.t;
  output_tokens : int;
  cache_hit_pct : float Observed.t;
  cost_usd : float;
  calls : int;
  failed : int;
  deferred : int;
  tool_ms : float;
}

type fleet_efficiency = {
  turns_total : int;
  calls_per_turn : float;
  tool_s_per_turn : float;
  output_tokens_per_turn : float;
  input_tokens_per_turn : float;
  cost_usd_per_turn : float;
  fleet_cache_hit_pct : float Observed.t;
}

type token_velocity_sample = {
  at_unix : float;
  input_tok_per_min : float Observed.t;
  cache_read_tok_per_min : float Observed.t;
  output_tok_per_min : float Observed.t;
}

type efficiency_window_kind =
  | Efficiency_month_mtd
  | Efficiency_month_complete

type efficiency_month = {
  month : string;
  window_kind : efficiency_window_kind option;
  generated_at_unix : float;
  days_covered : int;
  keepers : keeper_efficiency_row list;
  fleet : fleet_efficiency;
  velocity : token_velocity_sample list;
}

let decode_efficiency_window_kind json =
  let* raw = optional_string_field json "window_kind" in
  match raw with
  | None -> Ok None
  | Some "month_mtd" -> Ok (Some Efficiency_month_mtd)
  | Some "month_complete" -> Ok (Some Efficiency_month_complete)
  | Some other ->
      Error (Printf.sprintf "unexpected efficiency window_kind %S" other)

let compute_cache_hit_pct ~input_tokens ~cache_read_tokens =
  if input_tokens <= 0 || cache_read_tokens < 0 then None
  else
    let pct =
      Float.of_int cache_read_tokens *. 100.0 /. Float.of_int input_tokens
    in
    Some (Float.min 100.0 (Float.max 0.0 pct))

let decode_keeper_efficiency_row ~observed_at json =
  let* keeper = required_nonblank_string json "keeper" in
  let* turns = required_nonnegative_int_field json "turns" in
  let* input_tokens = required_nonnegative_int_field json "input_tokens" in
  let* cache_read_tokens = observed_int ~observed_at json "cache_read_tokens" in
  let* cache_creation_tokens =
    observed_int ~observed_at json "cache_creation_tokens"
  in
  let* output_tokens = required_nonnegative_int_field json "output_tokens" in
  let* explicit_cache_pct = observed_float ~observed_at json "cache_hit_pct" in
  let cache_hit_pct =
    match (explicit_cache_pct, Observed.to_option cache_read_tokens) with
    | Observed.Unreported, Some read_tok -> (
        (* Legacy fallback strictly when an older server omitted the
           [cache_hit_pct] key; an explicit JSON [null] ([Observed.Absent]) is
           authoritative (e.g. unpaired rows) and must never be recomputed. *)
        match compute_cache_hit_pct ~input_tokens ~cache_read_tokens:read_tok with
        | Some pct -> Observed.value ~observed_at pct
        | None -> Observed.absent)
    | Observed.Unreported, None
    | (Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Failed _), _ ->
        explicit_cache_pct
  in
  let* cost_usd = required_nonnegative_float json "cost_usd" in
  let* calls = required_nonnegative_int_field json "calls" in
  let* failed = required_nonnegative_int_field json "failed" in
  let* deferred = required_nonnegative_int_field json "deferred" in
  let* tool_ms = required_nonnegative_float json "tool_ms" in
  Ok
    {
      keeper;
      turns;
      input_tokens;
      cache_read_tokens;
      cache_creation_tokens;
      output_tokens;
      cache_hit_pct;
      cost_usd;
      calls;
      failed;
      deferred;
      tool_ms;
    }

let decode_velocity_sample ~observed_at json =
  let* at_unix = required_finite_float json "at_unix" in
  let* input_tok_per_min =
    observed_float ~observed_at json "input_tok_per_min"
  in
  let* cache_read_tok_per_min =
    observed_float ~observed_at json "cache_read_tok_per_min"
  in
  let* output_tok_per_min =
    observed_float ~observed_at json "output_tok_per_min"
  in
  Ok { at_unix; input_tok_per_min; cache_read_tok_per_min; output_tok_per_min }

let decode_efficiency_month ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* schema = required_nonblank_string body "schema" in
  let* () =
    if String.equal schema "masc.keeper-efficiency/v1" then Ok ()
    else Error (Printf.sprintf "unexpected efficiency schema %S" schema)
  in
  let* month = required_nonblank_string body "month" in
  let* window_kind = decode_efficiency_window_kind body in
  let* generated_at_unix = required_nonnegative_float body "generated_at" in
  let* days_covered = required_nonnegative_int_field body "days_covered" in
  let* keeper_items = required_list_field body "keepers" in
  let* keepers =
    decode_list "keepers" (decode_keeper_efficiency_row ~observed_at) keeper_items
  in
  let* fleet_obj = required_object_field body "fleet" in
  let* turns_total = required_nonnegative_int_field fleet_obj "turns_total" in
  let* calls_per_turn = required_nonnegative_float fleet_obj "calls_per_turn" in
  let* tool_s_per_turn =
    required_nonnegative_float fleet_obj "tool_s_per_turn"
  in
  let* output_tokens_per_turn =
    required_nonnegative_float fleet_obj "output_tokens_per_turn"
  in
  let* input_tokens_per_turn =
    required_nonnegative_float fleet_obj "input_tokens_per_turn"
  in
  let* cost_usd_per_turn =
    required_nonnegative_float fleet_obj "cost_usd_per_turn"
  in
  let* fleet_cache_hit_pct_raw =
    observed_float ~observed_at fleet_obj "cache_hit_pct"
  in
  let fleet_cache_hit_pct =
    match fleet_cache_hit_pct_raw with
    | Observed.Unreported ->
        (* Legacy fallback strictly when an older server omitted
           [fleet.cache_hit_pct]; explicit JSON [null] ([Observed.Absent]) is
           authoritative and must not be overwritten with unpaired totals. *)
        let sum_in, sum_cr =
          List.fold_left
            (fun (acc_in, acc_cr) (k : keeper_efficiency_row) ->
              match Observed.to_option k.cache_read_tokens with
              | Some cr when k.input_tokens > 0 ->
                  (acc_in + k.input_tokens, acc_cr + cr)
              | Some _ | None -> (acc_in, acc_cr))
            (0, 0) keepers
        in
        (match compute_cache_hit_pct ~input_tokens:sum_in ~cache_read_tokens:sum_cr with
        | Some pct -> Observed.value ~observed_at pct
        | None -> fleet_cache_hit_pct_raw)
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Failed _ ->
        fleet_cache_hit_pct_raw
  in
  let* velocity_items = optional_list_field body "velocity" in
  let* velocity =
    decode_list "velocity" (decode_velocity_sample ~observed_at) velocity_items
  in
  Ok
    {
      month;
      window_kind;
      generated_at_unix;
      days_covered;
      keepers;
      fleet =
        {
          turns_total;
          calls_per_turn;
          tool_s_per_turn;
          output_tokens_per_turn;
          input_tokens_per_turn;
          cost_usd_per_turn;
          fleet_cache_hit_pct;
        };
      velocity;
    }

type paired_cached_input = {
  input_tokens : int;
  cache_read_tokens : int;
  sample_count : int;
}

type model_metrics_bucket = {
  ts_start : float;
  entry_count : int;
  success_count : int;
  error_count : int;
  p50_latency_ms : float option;
  p95_latency_ms : float option;
  error_rate : float;
  total_cost_usd : float option;
  cache_hit_ratio : float option;
  input_tokens : int option;
  output_tokens : int option;
  cache_read_tokens : int option;
}

type model_metrics_row = {
  model_id : string;
  entry_count : int;
  success_count : int;
  error_count : int;
  avg_tok_per_sec : float option;
  p50_latency_ms : float option;
  p95_latency_ms : float option;
  total_input_tokens : int option;
  total_output_tokens : int option;
  total_cache_read_tokens : int option;
  total_cache_creation_tokens : int option;
  cached_input : paired_cached_input option;
  total_cost_usd : float option;
  total_tool_calls : int;
  buckets : model_metrics_bucket list;
}

type aggregated_metrics_bucket = {
  ts_start : float;
  entry_count : int;
  success_count : int;
  error_count : int;
  total_cost_usd : float;
  p95_latency_ms : float option;
  cache_hit_pct : float option;
  input_tokens : int option;
  output_tokens : int option;
  cache_read_tokens : int option;
}

type models_metrics_snapshot = {
  window_minutes : int;
  bucket_minutes : int;
  total_entries : int;
  total_error_entries : int;
  models : model_metrics_row list;
  hourly_buckets : aggregated_metrics_bucket list;
  fleet_cache_hit_pct : float Observed.t;
  fleet_cost_usd : float Observed.t;
  fleet_input_tokens : int;
  fleet_output_tokens : int;
  fleet_cache_read_tokens : int;
  fleet_cache_creation_tokens : int;
  fleet_tool_calls : int;
  fleet_p95_latency_ms : float option;
}

type runtime_metrics_state =
  | Runtime_metrics_ready
  | Runtime_metrics_unavailable of string

type runtime_metrics_snapshot = {
  state : runtime_metrics_state;
  observed_at_unix : float option;
  window_minutes : int;
  attributed_entries : int;
  unattributed_entries : int;
  runtimes : model_metrics_row list;
  hourly_buckets : aggregated_metrics_bucket list;
  fleet_cache_hit_pct : float Observed.t;
  fleet_cost_usd : float Observed.t;
  fleet_input_tokens : int;
  fleet_output_tokens : int;
  fleet_cache_read_tokens : int;
  fleet_cache_creation_tokens : int;
  fleet_tool_calls : int;
}

let optional_nonnegative_int_opt json key =
  match optional_int_field json key with
  | Error _ as err -> err
  | Ok None -> Ok None
  | Ok (Some n) when n >= 0 -> Ok (Some n)
  | Ok (Some n) -> Error (Printf.sprintf "field %S must be >= 0, got %d" key n)

let decode_paired_cached_input json =
  match optional_object_field json "cached_input" with
  | Error _ as err -> err
  | Ok None -> Ok None
  | Ok (Some ci) ->
      let* input_tokens = required_nonnegative_int_field ci "input_tokens" in
      let* cache_read_tokens =
        required_nonnegative_int_field ci "cache_read_tokens"
      in
      let* sample_count = required_nonnegative_int_field ci "sample_count" in
      Ok (Some { input_tokens; cache_read_tokens; sample_count })

let decode_model_metrics_bucket json =
  let* ts_start = required_finite_float json "ts_start" in
  let* entry_count = required_nonnegative_int_field json "entry_count" in
  let* success_count = int_field_or json "success_count" ~default:0 in
  let* error_count = int_field_or json "error_count" ~default:0 in
  let* p50_latency_ms = optional_finite_float json "p50_latency_ms" in
  let* p95_latency_ms = optional_finite_float json "p95_latency_ms" in
  let* error_rate =
    match optional_finite_float json "error_rate" with
    | Ok (Some r) -> Ok r
    | Ok None ->
        Ok
          (if entry_count > 0 then
             Float.of_int error_count /. Float.of_int entry_count
           else 0.0)
    | Error _ as err -> err
  in
  let* total_cost_usd = optional_finite_float json "total_cost_usd" in
  let* cache_hit_ratio = optional_finite_float json "cache_hit_ratio" in
  let* input_tokens = optional_nonnegative_int_opt json "input_tokens" in
  let* output_tokens = optional_nonnegative_int_opt json "output_tokens" in
  let* cache_read_tokens = optional_nonnegative_int_opt json "cache_read_tokens" in
  Ok
    {
      ts_start;
      entry_count;
      success_count;
      error_count;
      p50_latency_ms;
      p95_latency_ms;
      error_rate;
      total_cost_usd;
      cache_hit_ratio;
      input_tokens;
      output_tokens;
      cache_read_tokens;
    }

let decode_model_metrics_row ~id_field json =
  let* model_id = required_nonblank_string json id_field in
  let* entry_count = required_nonnegative_int_field json "entry_count" in
  let* success_count = int_field_or json "success_count" ~default:0 in
  let* error_count = int_field_or json "error_count" ~default:0 in
  let* avg_tok_per_sec = optional_finite_float json "avg_tok_per_sec" in
  let* p50_latency_ms = optional_finite_float json "p50_latency_ms" in
  let* p95_latency_ms = optional_finite_float json "p95_latency_ms" in
  let* total_input_tokens =
    optional_nonnegative_int_opt json "total_input_tokens"
  in
  let* total_output_tokens =
    optional_nonnegative_int_opt json "total_output_tokens"
  in
  let* total_cache_read_tokens =
    optional_nonnegative_int_opt json "total_cache_read_tokens"
  in
  let* total_cache_creation_tokens =
    optional_nonnegative_int_opt json "total_cache_creation_tokens"
  in
  let* cached_input = decode_paired_cached_input json in
  let* total_cost_usd = optional_finite_float json "total_cost_usd" in
  let* total_tool_calls = int_field_or json "total_tool_calls" ~default:0 in
  let* bucket_items = optional_list_field json "buckets" in
  let* buckets =
    decode_list "buckets" decode_model_metrics_bucket bucket_items
  in
  Ok
    {
      model_id;
      entry_count;
      success_count;
      error_count;
      avg_tok_per_sec;
      p50_latency_ms;
      p95_latency_ms;
      total_input_tokens;
      total_output_tokens;
      total_cache_read_tokens;
      total_cache_creation_tokens;
      cached_input;
      total_cost_usd;
      total_tool_calls;
      buckets;
    }

type bucket_accum = {
  mutable b_entries : int;
  mutable b_success : int;
  mutable b_errors : int;
  mutable b_cost : float;
  mutable b_p95 : float option;
  mutable b_cache_w_sum : float;
  mutable b_cache_weight : int;
  mutable b_in_tok : int option;
  mutable b_out_tok : int option;
  mutable b_cr_tok : int option;
}

let add_opt_int cur = function
  | None -> cur
  | Some v -> Some (Option.value ~default:0 cur + v)

let aggregate_model_buckets (rows : model_metrics_row list) :
    aggregated_metrics_bucket list =
  let tbl : (int, float * bucket_accum) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun (row : model_metrics_row) ->
      List.iter
        (fun (b : model_metrics_bucket) ->
          let key = Int.of_float (Float.round b.ts_start) in
          let _, acc =
            match Hashtbl.find_opt tbl key with
            | Some pair -> pair
            | None ->
                let fresh =
                  {
                    b_entries = 0;
                    b_success = 0;
                    b_errors = 0;
                    b_cost = 0.0;
                    b_p95 = None;
                    b_cache_w_sum = 0.0;
                    b_cache_weight = 0;
                    b_in_tok = None;
                    b_out_tok = None;
                    b_cr_tok = None;
                  }
                in
                Hashtbl.replace tbl key (b.ts_start, fresh);
                (b.ts_start, fresh)
          in
          acc.b_entries <- acc.b_entries + b.entry_count;
          acc.b_success <- acc.b_success + b.success_count;
          acc.b_errors <- acc.b_errors + b.error_count;
          (match b.total_cost_usd with
          | Some c when c >= 0.0 -> acc.b_cost <- acc.b_cost +. c
          | Some _ | None -> ());
          (match b.p95_latency_ms with
          | Some p when p >= 0.0 -> (
              match acc.b_p95 with
              | None -> acc.b_p95 <- Some p
              | Some prev -> acc.b_p95 <- Some (Float.max prev p))
          | Some _ | None -> ());
          (match b.cache_hit_ratio with
          | Some r when Float.is_finite r && r >= 0.0 ->
              let w = max 1 b.entry_count in
              let pct = Float.min 100.0 (Float.max 0.0 (r *. 100.0)) in
              acc.b_cache_w_sum <- acc.b_cache_w_sum +. (pct *. Float.of_int w);
              acc.b_cache_weight <- acc.b_cache_weight + w
          | Some _ | None -> ());
          acc.b_in_tok <- add_opt_int acc.b_in_tok b.input_tokens;
          acc.b_out_tok <- add_opt_int acc.b_out_tok b.output_tokens;
          acc.b_cr_tok <- add_opt_int acc.b_cr_tok b.cache_read_tokens)
        row.buckets)
    rows;
  Hashtbl.fold
    (fun _ (ts_start, acc) out ->
      let cache_hit_pct =
        if acc.b_cache_weight > 0 then
          Some (acc.b_cache_w_sum /. Float.of_int acc.b_cache_weight)
        else
          match (acc.b_in_tok, acc.b_cr_tok) with
          | Some inp, Some cr ->
              compute_cache_hit_pct ~input_tokens:inp ~cache_read_tokens:cr
          | Some _, None | None, Some _ | None, None -> None
      in
      {
        ts_start;
        entry_count = acc.b_entries;
        success_count = acc.b_success;
        error_count = acc.b_errors;
        total_cost_usd = acc.b_cost;
        p95_latency_ms = acc.b_p95;
        cache_hit_pct;
        input_tokens = acc.b_in_tok;
        output_tokens = acc.b_out_tok;
        cache_read_tokens = acc.b_cr_tok;
      }
      :: out)
    tbl []
  |> List.sort (fun (a : aggregated_metrics_bucket) b ->
         Float.compare a.ts_start b.ts_start)

let summarize_metrics_rows ~observed_at (rows : model_metrics_row list)
    (hourly_buckets : aggregated_metrics_bucket list) =
  let ci_in = ref 0 in
  let ci_cr = ref 0 in
  let pair_in = ref 0 in
  let pair_cr = ref 0 in
  let tot_in = ref 0 in
  let tot_out = ref 0 in
  let tot_cr = ref 0 in
  let tot_cc = ref 0 in
  let tot_tools = ref 0 in
  let cost_sum = ref 0.0 in
  let cost_seen = ref false in
  let p95_max = ref None in
  List.iter
    (fun (r : model_metrics_row) ->
      (match r.cached_input with
      | Some ci when ci.input_tokens > 0 ->
          ci_in := !ci_in + ci.input_tokens;
          ci_cr := !ci_cr + ci.cache_read_tokens
      | Some _ | None -> ());
      (match (r.total_input_tokens, r.total_cache_read_tokens) with
      | Some inp, Some cr when inp > 0 ->
          pair_in := !pair_in + inp;
          pair_cr := !pair_cr + cr
      | _ -> ());
      tot_in := !tot_in + Option.value ~default:0 r.total_input_tokens;
      tot_out := !tot_out + Option.value ~default:0 r.total_output_tokens;
      tot_cr := !tot_cr + Option.value ~default:0 r.total_cache_read_tokens;
      tot_cc := !tot_cc + Option.value ~default:0 r.total_cache_creation_tokens;
      tot_tools := !tot_tools + r.total_tool_calls;
      (match r.total_cost_usd with
      | Some c when Float.is_finite c && c >= 0.0 ->
          cost_seen := true;
          cost_sum := !cost_sum +. c
      | Some _ | None -> ());
      match r.p95_latency_ms with
      | Some p when Float.is_finite p && p >= 0.0 -> (
          match !p95_max with
          | None -> p95_max := Some p
          | Some prev -> p95_max := Some (Float.max prev p))
      | Some _ | None -> ())
    rows;
  let fleet_cache_hit_pct =
    match compute_cache_hit_pct ~input_tokens:!ci_in ~cache_read_tokens:!ci_cr with
    | Some pct -> Observed.value ~observed_at pct
    | None -> (
        match
          compute_cache_hit_pct ~input_tokens:!pair_in ~cache_read_tokens:!pair_cr
        with
        | Some pct -> Observed.value ~observed_at pct
        | None ->
            let w_sum, w_tot =
              List.fold_left
                (fun (ws, wt) (b : aggregated_metrics_bucket) ->
                  match b.cache_hit_pct with
                  | Some pct ->
                      let w = max 1 b.entry_count in
                      (ws +. (pct *. Float.of_int w), wt + w)
                  | None -> (ws, wt))
                (0.0, 0) hourly_buckets
            in
            if w_tot > 0 then
              Observed.value ~observed_at (w_sum /. Float.of_int w_tot)
            else Observed.unreported)
  in
  let fleet_cost_usd =
    if !cost_seen then Observed.value ~observed_at !cost_sum
    else Observed.unreported
  in
  ( fleet_cache_hit_pct
  , fleet_cost_usd
  , !tot_in
  , !tot_out
  , !tot_cr
  , !tot_cc
  , !tot_tools
  , !p95_max )

let decode_models_metrics ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* window_minutes = required_nonnegative_int_field body "window_minutes" in
  let* bucket_minutes = int_field_or body "bucket_minutes" ~default:0 in
  let* total_entries = int_field_or body "total_entries" ~default:0 in
  let* total_error_entries = int_field_or body "total_error_entries" ~default:0 in
  let* model_items = required_list_field body "models" in
  let* models =
    decode_list "models" (decode_model_metrics_row ~id_field:"model_id")
      model_items
  in
  let hourly_buckets = aggregate_model_buckets models in
  let ( fleet_cache_hit_pct
      , fleet_cost_usd
      , fleet_input_tokens
      , fleet_output_tokens
      , fleet_cache_read_tokens
      , fleet_cache_creation_tokens
      , fleet_tool_calls
      , fleet_p95_latency_ms ) =
    summarize_metrics_rows ~observed_at models hourly_buckets
  in
  Ok
    {
      window_minutes;
      bucket_minutes;
      total_entries;
      total_error_entries;
      models;
      hourly_buckets;
      fleet_cache_hit_pct;
      fleet_cost_usd;
      fleet_input_tokens;
      fleet_output_tokens;
      fleet_cache_read_tokens;
      fleet_cache_creation_tokens;
      fleet_tool_calls;
      fleet_p95_latency_ms;
    }

let decode_runtime_metrics ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* history = required_object_field body "history" in
  let* state_str = required_nonblank_string history "state" in
  match state_str with
  | "unavailable" ->
      let* reason =
        match optional_nonblank_string history "reason" with
        | Ok (Some r) -> Ok r
        | Ok None -> Ok "unavailable"
        | Error _ as err -> err
      in
      Ok
        {
          state = Runtime_metrics_unavailable reason;
          observed_at_unix = None;
          window_minutes = 0;
          attributed_entries = 0;
          unattributed_entries = 0;
          runtimes = [];
          hourly_buckets = [];
          fleet_cache_hit_pct = Observed.unreported;
          fleet_cost_usd = Observed.unreported;
          fleet_input_tokens = 0;
          fleet_output_tokens = 0;
          fleet_cache_read_tokens = 0;
          fleet_cache_creation_tokens = 0;
          fleet_tool_calls = 0;
        }
  | "ready" ->
      let* observed_at_unix = optional_finite_float history "observed_at" in
      let* window_minutes = int_field_or history "window_minutes" ~default:1440 in
      let* attributed_entries =
        int_field_or history "attributed_entries" ~default:0
      in
      let* unattributed_entries =
        int_field_or history "unattributed_entries" ~default:0
      in
      let* rt_items = optional_list_field history "runtimes" in
      let* runtimes =
        decode_list "runtimes" (decode_model_metrics_row ~id_field:"runtime_id")
          rt_items
      in
      let hourly_buckets = aggregate_model_buckets runtimes in
      let ( fleet_cache_hit_pct
          , fleet_cost_usd
          , fleet_input_tokens
          , fleet_output_tokens
          , fleet_cache_read_tokens
          , fleet_cache_creation_tokens
          , fleet_tool_calls
          , _p95 ) =
        summarize_metrics_rows ~observed_at runtimes hourly_buckets
      in
      Ok
        {
          state = Runtime_metrics_ready;
          observed_at_unix;
          window_minutes;
          attributed_entries;
          unattributed_entries;
          runtimes;
          hourly_buckets;
          fleet_cache_hit_pct;
          fleet_cost_usd;
          fleet_input_tokens;
          fleet_output_tokens;
          fleet_cache_read_tokens;
          fleet_cache_creation_tokens;
          fleet_tool_calls;
        }
  | other ->
      Error (Printf.sprintf "unknown runtime/metrics history state %S" other)

type failover_lane = {
  id : string;
  declared : bool;
  runtime_ids : string list;
}

type runtime_option = {
  id : string;
  provider_id : string;
  provider : string;
  model : string option;
  declared_reasoning_effort : string option;
  transport : string option;
  is_default : bool;
}

type runtime_resolved_snapshot = {
  generated_at_iso : string;
  config_path : string option;
  default_route : string option;
  lanes : failover_lane list;
  runtimes : runtime_option list;
  usage_windows : provider_usage_windows option;
}

let decode_failover_lane json =
  let* id = required_nonblank_string json "id" in
  let* declared = required_bool_field json "declared" in
  let* runtime_ids = required_string_list json "runtime_ids" in
  let* () =
    match runtime_ids with
    | [] -> Error (Printf.sprintf "failover lane %S has no candidates" id)
    | _ :: _ -> Ok ()
  in
  Ok { id; declared; runtime_ids }

let decode_runtime_option ~default_route json =
  let* id = required_nonblank_string json "id" in
  let* provider = required_nonblank_string json "provider" in
  let* provider_id_opt = optional_nonblank_string json "provider_id" in
  let provider_id = Option.value provider_id_opt ~default:provider in
  let* model = optional_nonblank_string json "model" in
  let* declared_reasoning_effort =
    optional_nonblank_string json "declared_reasoning_effort"
  in
  let* transport = optional_nonblank_string json "transport" in
  let is_default =
    match default_route with Some d -> String.equal d id | None -> false
  in
  Ok
    {
      id;
      provider_id;
      provider;
      model;
      declared_reasoning_effort;
      transport;
      is_default;
    }

let decode_runtime_resolved json =
  let* _, body = unwrap_v2_or_raw json in
  let* generated_at_iso = required_nonblank_string body "generated_at_iso" in
  let* source = required_nonblank_string body "source" in
  let* () =
    if
      String.equal source "/api/v1/runtime/resolved"
      || String.equal source "/api/v1/dashboard/runtime/resolved"
    then Ok ()
    else
      Error
        (Printf.sprintf "unexpected runtime resolved source %S" source)
  in
  let* config_path = required_nullable_string_field body "config_path" in
  let* default_route = required_nullable_string_field body "default_route" in
  let* lane_items = optional_list_field body "lanes" in
  let* lanes = decode_list "lanes" decode_failover_lane lane_items in
  let* rt_items = optional_list_field body "runtimes" in
  let* runtimes =
    decode_list "runtimes" (decode_runtime_option ~default_route) rt_items
  in
  let* usage_windows =
    if has_field body "provider_usage_windows" then
      let* u = decode_provider_usage_windows body in
      Ok (Some u)
    else Ok None
  in
  Ok { generated_at_iso; config_path; default_route; lanes; runtimes; usage_windows }

let is_hex_char = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let is_hex_string s =
  let len = String.length s in
  len > 0
  &&
  let rec loop i =
    if i >= len then true
    else if is_hex_char s.[i] then loop (i + 1)
    else false
  in
  loop 0

let split_trailing_hex8 raw =
  let len = String.length raw in
  if len > 9 && raw.[len - 9] = '_' then
    let suffix = String.sub raw (len - 8) 8 in
    if is_hex_string suffix then
      Some (String.sub raw 0 (len - 9), String.lowercase_ascii suffix)
    else None
  else None

let generic_runtime_prefixes =
  [
    "claude";
    "claude_code";
    "codex";
    "antigravity";
    "default";
    "local";
    "main";
  ]

let binding_tag_for_provider ~runtimes provider_id =
  let low_pid = String.lowercase_ascii (String.trim provider_id) in
  List.find_map
    (fun (rt : runtime_option) ->
      if
        not
          (String.equal rt.provider_id provider_id
          || String.equal rt.provider provider_id)
      then None
      else
        let id = String.trim rt.id in
        match String.index_opt id '.' with
        | Some idx when idx > 0 ->
            let prefix = String.trim (String.sub id 0 idx) in
            let low = String.lowercase_ascii prefix in
            if
              String.equal low ""
              || String.equal low low_pid
              || List.mem low generic_runtime_prefixes
              || Option.is_some (split_trailing_hex8 prefix)
            then None
            else Some prefix
        | Some _ | None -> None)
    runtimes

let is_raw_slug_display ~raw_id disp =
  let d = String.trim disp in
  String.equal d ""
  || String.equal d raw_id
  || Option.is_some (split_trailing_hex8 d)

let title_case_provider_id raw =
  String.split_on_char '_' raw
  |> List.concat_map (String.split_on_char '-')
  |> List.filter (fun s -> not (String.equal s ""))
  |> List.map String.capitalize_ascii
  |> String.concat " "

let human_provider_id_label ?(runtimes = []) ?display_name provider_id =
  let raw = String.trim provider_id in
  let low = String.lowercase_ascii raw in
  match low with
  | "glm-coding" -> "Z.AI Coding"
  | "openrouter" -> "OpenRouter"
  | "ollama_cloud" -> "Ollama Cloud"
  | "kimi_coding" -> "Kimi Coding"
  | "opencode_go" -> "OpenCode Go"
  | "mistral" -> "Mistral"
  | "tinker" -> "Tinker"
  | "openai-responses" -> (
      match display_name with
      | Some d when not (is_raw_slug_display ~raw_id:raw d) -> String.trim d
      | Some _ | None -> "OpenAI API")
  | _ -> (
      match split_trailing_hex8 raw with
      | Some (base, hex8) -> (
          let short4 = String.sub hex8 0 4 in
          let explicit_display =
            match display_name with
            | Some d ->
                let trimmed = String.trim d in
                let low_d = String.lowercase_ascii trimmed in
                if
                  (not (is_raw_slug_display ~raw_id:raw trimmed))
                  && (not (String.equal low_d "claude code"))
                  && (not (String.equal low_d (String.lowercase_ascii base)))
                then Some trimmed
                else None
            | None -> None
          in
          match explicit_display with
          | Some d -> d
          | None -> (
              match String.lowercase_ascii base with
              | "claude_code" -> (
                  match binding_tag_for_provider ~runtimes raw with
                  | Some tag -> Printf.sprintf "Claude Code (%s)" tag
                  | None -> Printf.sprintf "Claude Code #%s" short4)
              | "antigravity" -> "Antigravity CLI"
              | "codex" -> "Codex CLI"
              | other ->
                  Printf.sprintf "%s #%s" (title_case_provider_id other) short4))
      | None -> (
          match display_name with
          | Some d ->
              let trimmed = String.trim d in
              if String.equal (String.lowercase_ascii trimmed)
                   "kimi for coding subscription"
              then "Kimi Coding"
              else if not (is_raw_slug_display ~raw_id:raw trimmed) then trimmed
              else title_case_provider_id raw
          | None -> title_case_provider_id raw))

let base_account_label ~lang ~runtimes (acc : account_usage) =
  let codex_count =
    List.fold_left
      (fun n (p : usage_provider_ref) ->
        let low = String.lowercase_ascii p.id in
        if String.equal low "codex" || String.starts_with ~prefix:"codex_" low then
          n + 1
        else n)
      0 acc.providers
  in
  if
    codex_count > 1
    || (String.equal (String.lowercase_ascii (String.trim acc.scope)) "codex"
       && List.length acc.providers > 1)
  then
    let n = List.length acc.providers in
    match lang with
    | Say.Lang_ko -> Printf.sprintf "Codex CLI (%d계정)" n
    | Say.Lang_en -> Printf.sprintf "Codex CLI (%d accounts)" n
  else
    match acc.providers with
    | p :: _ ->
        human_provider_id_label ~runtimes ~display_name:p.display_name p.id
    | [] ->
        human_provider_id_label ~runtimes acc.scope

let human_provider_label ?(lang = Say.Lang_ko) ?(runtimes = [])
    ?(all_accounts = []) (acc : account_usage) =
  let base = base_account_label ~lang ~runtimes acc in
  let collides =
    List.exists
      (fun (other : account_usage) ->
        (not (String.equal other.scope_id acc.scope_id))
        && String.equal (base_account_label ~lang ~runtimes other) base)
      all_accounts
  in
  if not collides then base
  else
    let short_tag =
      match acc.providers with
      | p :: _ -> (
          match split_trailing_hex8 p.id with
          | Some (_, hex8) -> String.sub hex8 0 4
          | None ->
              if String.length acc.scope_id > 4 then String.sub acc.scope_id 0 4
              else acc.scope_id)
      | [] ->
          if String.length acc.scope_id > 4 then String.sub acc.scope_id 0 4
          else acc.scope_id
    in
    Printf.sprintf "%s #%s" base short_tag

let human_runtime_slot_label ?(runtimes = []) runtime_id =
  let raw = String.trim runtime_id in
  match
    List.find_opt
      (fun (rt : runtime_option) -> String.equal rt.id raw)
      runtimes
  with
  | Some rt -> (
      let prov =
        human_provider_id_label ~runtimes ~display_name:rt.provider rt.provider_id
      in
      let effort_suffix =
        match rt.declared_reasoning_effort with
        | Some e when not (String.equal (String.trim e) "") ->
            "@" ^ String.trim e
        | Some _ | None -> ""
      in
      match rt.model with
      | Some mdl when not (String.equal (String.trim mdl) "") ->
          Printf.sprintf "%s · %s%s" prov (String.trim mdl) effort_suffix
      | Some _ | None -> prov ^ effort_suffix)
  | None -> (
      match String.index_opt raw '.' with
      | Some dot when dot > 0 && dot + 1 < String.length raw ->
          let prov_raw = String.sub raw 0 dot in
          let mdl_raw = String.sub raw (dot + 1) (String.length raw - dot - 1) in
          let prov = human_provider_id_label ~runtimes prov_raw in
          let mdl_clean =
            match split_trailing_hex8 mdl_raw with
            | Some (base, _) -> base
            | None -> mdl_raw
          in
          Printf.sprintf "%s · %s" prov mdl_clean
      | Some _ | None -> human_provider_id_label ~runtimes raw)

type probe_refresh_state =
  | Probe_fresh
  | Probe_recent
  | Probe_served_stale
  | Probe_warming_up

type probe_status =
  | Probe_ok
  | Probe_idle
  | Probe_degraded
  | Probe_unreachable
  | Probe_warming

type provider_probe_row = {
  runtime_id : string;
  transport : [ `Http | `Cli ];
  status : string;
  reachable : bool option;
  http_status : int option;
  latency_ms : float option;
  error : string option;
  checked_at : string;
}

type runtime_probe_snapshot = {
  generated_at : string;
  cache_ttl_sec : float;
  cache_age_sec : float option;
  cache_hit : bool;
  refresh_state : probe_refresh_state;
  status : probe_status;
  probe_ok : bool;
  default_runtime_id : string option;
  runtimes_count : int;
  probed_count : int;
  reachable_count : int;
  failed_count : int;
  skipped_count : int;
  providers : provider_probe_row list;
  errors : string list;
  observations : string list;
  limitations : string list;
}

let probe_refresh_state_of_string = function
  | "fresh" -> Some Probe_fresh
  | "recent" -> Some Probe_recent
  | "served_stale" -> Some Probe_served_stale
  | "warming_up" -> Some Probe_warming_up
  | _ -> None

let probe_status_of_string = function
  | "ok" -> Some Probe_ok
  | "idle" -> Some Probe_idle
  | "degraded" -> Some Probe_degraded
  | "unavailable" | "unreachable" -> Some Probe_unreachable
  | "warming_up" -> Some Probe_warming
  | _ -> None

let decode_provider_probe_row json =
  let* runtime_id = required_nonblank_string json "runtime_id" in
  let* transport_raw = required_nonblank_string json "transport" in
  let* transport =
    match transport_raw with
    | "http" -> Ok `Http
    | "cli" -> Ok `Cli
    | other -> Error (Printf.sprintf "unknown probe transport %S" other)
  in
  let* status = required_nonblank_string json "status" in
  let* reachable = optional_bool_field json "reachable" in
  let* http_status = optional_int_field json "http_status" in
  let* latency_ms = optional_finite_float json "latency_ms" in
  let* error = optional_nonblank_string json "error" in
  let* checked_at = required_nonblank_string json "checked_at" in
  Ok
    {
      runtime_id;
      transport;
      status;
      reachable;
      http_status;
      latency_ms;
      error;
      checked_at;
    }

let decode_runtime_probe json =
  let* _, body = unwrap_v2_or_raw json in
  let* generated_at = required_nonblank_string body "generated_at" in
  let* cache_ttl_sec = required_nonnegative_float body "cache_ttl_sec" in
  let* cache_age_sec = optional_finite_float body "cache_age_sec" in
  let* cache_hit = required_bool_field body "cache_hit" in
  let* refresh_state =
    decode_enum ~field:"refresh_state" probe_refresh_state_of_string body
  in
  (* Real server nests [status], [probe_ok], [summary], and [providers] inside [body.probe]. *)
  let* probe = required_object_field body "probe" in
  let* status = decode_enum ~field:"status" probe_status_of_string probe in
  let* probe_ok = required_bool_field probe "probe_ok" in
  let* summary = required_object_field probe "summary" in
  let* runtimes_count = required_nonnegative_int_field summary "runtimes" in
  let* probed_count = required_nonnegative_int_field summary "probed" in
  let* reachable_count = required_nonnegative_int_field summary "reachable" in
  let* failed_count = required_nonnegative_int_field summary "failed" in
  let* skipped_count = required_nonnegative_int_field summary "skipped" in
  let* default_runtime_id =
    optional_nonblank_string summary "default_runtime_id"
  in
  let* prov_items = required_list_field probe "providers" in
  let* providers = decode_list "providers" decode_provider_probe_row prov_items in
  let* errors = optional_string_list probe "errors" in
  let* observations = optional_string_list probe "observations" in
  let* limitations = optional_string_list probe "limitations" in
  Ok
    {
      generated_at;
      cache_ttl_sec;
      cache_age_sec;
      cache_hit;
      refresh_state;
      status;
      probe_ok;
      default_runtime_id;
      runtimes_count;
      probed_count;
      reachable_count;
      failed_count;
      skipped_count;
      providers;
      errors;
      observations;
      limitations;
    }

let partition_probe_by_active_lanes ~lanes (probe : runtime_probe_snapshot) =
  let active_ids = Hashtbl.create 32 in
  List.iter
    (fun (lane : failover_lane) ->
      List.iter (fun id -> Hashtbl.replace active_ids id ()) lane.runtime_ids)
    lanes;
  List.partition
    (fun (row : provider_probe_row) -> Hashtbl.mem active_ids row.runtime_id)
    probe.providers

type exact_output_status =
  | Exact_running
  | Exact_succeeded
  | Exact_cancelled
  | Exact_failed of { code : string; detail : string }
  | Exact_completion_persistence_failed
  | Exact_completion_durability_unknown

type task_review_status =
  | Task_review_running
  | Task_review_approved
  | Task_review_rejected
  | Task_review_infrastructure_unavailable
  | Task_review_not_reviewed
  | Task_review_commit_failed
  | Task_review_execution_pending
  | Task_review_execution_repair_required
  | Task_review_raised
  | Task_review_cancelled
  | Task_review_superseded

type goal_review_status =
  | Goal_review_running
  | Goal_review_reviewed
  | Goal_review_committed
  | Goal_review_superseded
  | Goal_review_deferred
  | Goal_review_raised
  | Goal_review_cancelled

type lane_run_status =
  | Exact_output of exact_output_status
  | Task_verification of task_review_status
  | Goal_verification of goal_review_status

type exact_lane_run = {
  run_id : string;
  lane : string;
  subject_id : string option;
  status : lane_run_status;
  started_at_unix : float;
}

let lane_run_status_label = function
  | Exact_output Exact_running -> "running"
  | Exact_output Exact_succeeded -> "succeeded"
  | Exact_output Exact_cancelled -> "cancelled"
  | Exact_output (Exact_failed _) -> "failed"
  | Exact_output Exact_completion_persistence_failed ->
      "completion_persistence_failed"
  | Exact_output Exact_completion_durability_unknown ->
      "completion_durability_unknown"
  | Task_verification Task_review_running -> "running"
  | Task_verification Task_review_approved -> "approved"
  | Task_verification Task_review_rejected -> "rejected"
  | Task_verification Task_review_infrastructure_unavailable ->
      "infrastructure_unavailable"
  | Task_verification Task_review_not_reviewed -> "not_reviewed"
  | Task_verification Task_review_commit_failed -> "commit_failed"
  | Task_verification Task_review_execution_pending -> "execution_pending"
  | Task_verification Task_review_execution_repair_required ->
      "execution_repair_required"
  | Task_verification Task_review_raised -> "raised"
  | Task_verification Task_review_cancelled -> "review_cancelled"
  | Task_verification Task_review_superseded -> "superseded_by"
  | Goal_verification Goal_review_running -> "running"
  | Goal_verification Goal_review_reviewed -> "reviewed"
  | Goal_verification Goal_review_committed -> "committed"
  | Goal_verification Goal_review_superseded -> "superseded"
  | Goal_verification Goal_review_deferred -> "deferred"
  | Goal_verification Goal_review_raised -> "raised"
  | Goal_verification Goal_review_cancelled -> "review_cancelled"

let decode_exact_output_status json = function
  | "running" -> Ok Exact_running
  | "succeeded" -> Ok Exact_succeeded
  | "cancelled" -> Ok Exact_cancelled
  | "failed" ->
      let* code = required_string_field json "code" in
      let* detail = required_string_field json "detail" in
      Ok (Exact_failed { code; detail })
  | "completion_persistence_failed" -> Ok Exact_completion_persistence_failed
  | "completion_durability_unknown" -> Ok Exact_completion_durability_unknown
  | other -> Error (Printf.sprintf "unknown exact_output run status %S" other)

let decode_task_review_status = function
  | "running" -> Ok Task_review_running
  | "approved" -> Ok Task_review_approved
  | "rejected" -> Ok Task_review_rejected
  | "infrastructure_unavailable" -> Ok Task_review_infrastructure_unavailable
  | "not_reviewed" -> Ok Task_review_not_reviewed
  | "commit_failed" -> Ok Task_review_commit_failed
  | "execution_pending" -> Ok Task_review_execution_pending
  | "execution_repair_required" -> Ok Task_review_execution_repair_required
  | "raised" -> Ok Task_review_raised
  | "review_cancelled" -> Ok Task_review_cancelled
  | "superseded_by" -> Ok Task_review_superseded
  | other ->
      Error (Printf.sprintf "unknown task_verification run status %S" other)

let decode_goal_review_status = function
  | "running" -> Ok Goal_review_running
  | "reviewed" -> Ok Goal_review_reviewed
  | "committed" -> Ok Goal_review_committed
  | "superseded" -> Ok Goal_review_superseded
  | "deferred" -> Ok Goal_review_deferred
  | "raised" -> Ok Goal_review_raised
  | "review_cancelled" -> Ok Goal_review_cancelled
  | other ->
      Error (Printf.sprintf "unknown goal_verification run status %S" other)

let decode_exact_lane_run json =
  let* run_id = required_nonblank_string json "run_id" in
  let* run_kind = required_nonblank_string json "run_kind" in
  let* lane = required_nonblank_string json "lane" in
  let* subject_id = optional_nonblank_string json "subject_id" in
  let* status_label = required_nonblank_string json "status" in
  let* started_at_unix = required_finite_float json "started_at" in
  let* status =
    match run_kind with
    | "exact_output" ->
        let* s = decode_exact_output_status json status_label in
        Ok (Exact_output s)
    | "task_verification" ->
        let* s = decode_task_review_status status_label in
        Ok (Task_verification s)
    | "goal_verification" ->
        let* s = decode_goal_review_status status_label in
        Ok (Goal_verification s)
    | other -> Error (Printf.sprintf "unknown lane run_kind %S" other)
  in
  Ok { run_id; lane; subject_id; status; started_at_unix }

let decode_exact_lane_runs json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "runs" in
  decode_list "runs" decode_exact_lane_run items

type fusion_topology =
  | Simple
  | Refine
  | Conditional
  | Judge_of_judges
  | Staged_judge_of_judges

type fusion_run_status =
  | Fusion_running
  | Fusion_completed
  | Fusion_failed of { code : string; error : string }

type fusion_run = {
  run_id : string;
  keeper : string;
  preset : string;
  topology : fusion_topology;
  started_at_unix : float;
  finished_at_unix : float option;
  status : fusion_run_status;
  stage : string;
  decision : string option;
  summary : string option;
}

type fusion_launch_request = {
  prompt : string;
  preset : string option;
  topology : fusion_topology option;
  web_tools : bool;
}

let fusion_topology_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "simple" -> Some Simple
  | "refine" -> Some Refine
  | "conditional" -> Some Conditional
  | "judge_of_judges" -> Some Judge_of_judges
  | "staged_judge_of_judges" -> Some Staged_judge_of_judges
  | _ -> None

let fusion_topology_to_string = function
  | Simple -> "simple"
  | Refine -> "refine"
  | Conditional -> "conditional"
  | Judge_of_judges -> "judge_of_judges"
  | Staged_judge_of_judges -> "staged_judge_of_judges"

let decode_fusion_run json =
  let* run_id = required_nonblank_string json "run_id" in
  let* keeper = required_nonblank_string json "keeper" in
  let* preset = required_nonblank_string json "preset" in
  let* topology = decode_enum ~field:"topology" fusion_topology_of_string json in
  let* started_at_unix = required_finite_float json "started_at" in
  let* finished_at_unix = optional_finite_float json "finished_at" in
  let* status_str = required_nonblank_string json "status" in
  let* status =
    match status_str with
    | "running" -> Ok Fusion_running
    | "completed" -> Ok Fusion_completed
    | "failed" ->
        let* code = required_nonblank_string json "failure_code" in
        let* error = required_string_field json "error" in
        Ok (Fusion_failed { code; error })
    | other -> Error (Printf.sprintf "unknown fusion status %S" other)
  in
  let* stage = required_nonblank_string json "stage" in
  let* decision = optional_nonblank_string json "decision" in
  let* summary = optional_nonblank_string json "summary" in
  Ok
    {
      run_id;
      keeper;
      preset;
      topology;
      started_at_unix;
      finished_at_unix;
      status;
      stage;
      decision;
      summary;
    }

let decode_fusion_runs json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "runs" in
  decode_list "runs" decode_fusion_run items

let encode_fusion_launch req =
  `Assoc
    ([
       ("prompt", `String req.prompt);
       ("web_tools", `Bool req.web_tools);
     ]
    @ (match req.preset with
      | None -> []
      | Some p -> [ ("preset", `String p) ])
    @
    match req.topology with
    | None -> []
    | Some t -> [ ("topology", `String (fusion_topology_to_string t)) ])

type tool_series_activity =
  | Series_idle
  | Series_active of {
      calls : int;
      failures : int;
      deferred : int;
      p95_ms : float;
    }

type tool_series_bucket = {
  start_unix : float;
  activity : tool_series_activity;
}

type tool_series = {
  generated_at_unix : float;
  bucket_width : [ `Hour | `Day ];
  utc_offset_min : int;
  buckets : tool_series_bucket list;
}

let decode_tool_series_bucket json =
  let* start_unix = required_finite_float json "start" in
  let* calls = required_nonnegative_int_field json "call_count" in
  let* failures = required_nonnegative_int_field json "failure_count" in
  let* deferred =
    if has_field json "deferred_count" then
      required_nonnegative_int_field json "deferred_count"
    else Ok 0
  in
  let* p95 =
    if has_field json "p95_ms" then required_nullable_float_field json "p95_ms"
    else Ok None
  in
  let* activity =
    match (calls, p95) with
    | 0, None ->
        if failures = 0 && deferred = 0 then Ok Series_idle
        else Error "idle bucket cannot have failures or deferred calls"
    | 0, Some v when Float.equal v 0.0 ->
        if failures = 0 && deferred = 0 then Ok Series_idle
        else Error "idle bucket cannot have failures or deferred calls"
    | 0, Some _ -> Error "idle bucket cannot carry p95_ms"
    | _, None -> Error "active bucket requires p95_ms"
    | _, Some p95_ms ->
        if (not (Float.is_finite p95_ms)) || p95_ms < 0.0 then
          Error "p95_ms must be non-negative finite float"
        else if failures + deferred > calls then
          Error "failures + deferred exceeds call_count"
        else Ok (Series_active { calls; failures; deferred; p95_ms })
  in
  Ok { start_unix; activity }

let decode_tool_series json =
  let* _, body = unwrap_v2_or_raw json in
  let* generated_at_unix =
    if has_field body "generated_at" then required_finite_float body "generated_at"
    else Ok 0.0
  in
  let* width_str, utc_offset_min =
    match optional_object_field body "window" with
    | Error _ as err -> err
    | Ok (Some window) ->
        let* w = required_nonblank_string window "bucket" in
        let* off = required_int_field window "utc_offset_min" in
        Ok (w, off)
    | Ok None ->
        let* w = required_nonblank_string body "bucket" in
        let* off = int_field_or body "utc_offset_min" ~default:0 in
        Ok (w, off)
  in
  let* bucket_width =
    match width_str with
    | "hour" -> Ok `Hour
    | "day" -> Ok `Day
    | other -> Error (Printf.sprintf "unknown tool series bucket %S" other)
  in
  let* items =
    if has_field body "buckets" then required_list_field body "buckets"
    else required_list_field body "series"
  in
  let* buckets = decode_list "buckets" decode_tool_series_bucket items in
  match buckets with
  | [] -> Error "tool series has no buckets"
  | _ :: _ -> Ok { generated_at_unix; bucket_width; utc_offset_min; buckets }

type tool_summary = {
  name : string;
  description : string option;
  calls : int Observed.t;
  failure_rate_pct : float Observed.t;
}

type tools_catalog = Tools_warming | Tools_ready of tool_summary list

(* /api/v1/dashboard/tools. Until its first compute finishes the server
   answers a warming payload ([is_warming: true], empty lists). A ready
   payload carries [tool_inventory.tools] (every tool, hidden ones too) and
   Tool_unified.summary_report as [tool_usage]: [by_tool] holds one row per
   called tool over the retained metrics window, and [never_called] the
   visible tools with no call. Both key a tool by its internal name and list
   the [public_names] a Keeper sees, which the inventory also uses. *)
type tool_names = { internal_name : string; public_names : string list }

type tool_usage_row = {
  names : tool_names;
  call_count : int;
  failure_count : int;
}

let decode_tool_names json =
  let* internal_name = required_nonblank_string json "name" in
  let* public_names = required_string_list json "public_names" in
  Ok { internal_name; public_names }

let decode_tool_usage_row json =
  let* names = decode_tool_names json in
  let* call_count = required_nonnegative_int_field json "call_count" in
  let* failure_count = required_nonnegative_int_field json "failure_count" in
  Ok { names; call_count; failure_count }

(* The rows for one inventory name: the row with that internal name, or else
   the rows that publish the tool under that name. *)
let rows_named name ~names_of rows =
  match
    List.filter (fun row -> String.equal (names_of row).internal_name name) rows
  with
  | _ :: _ as same_internal -> same_internal
  | [] ->
      List.filter
        (fun row -> List.exists (String.equal name) (names_of row).public_names)
        rows

let decode_tools_catalog ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* warming =
    if has_field body "is_warming" then required_bool_field body "is_warming"
    else Ok false
  in
  if warming then Ok Tools_warming
  else
    let* inventory = required_object_field body "tool_inventory" in
    let* usage = required_object_field body "tool_usage" in
    let* tool_items = required_list_field inventory "tools" in
    let* called_items = required_list_field usage "by_tool" in
    let* called = decode_list "by_tool" decode_tool_usage_row called_items in
    let* never_items = required_list_field usage "never_called" in
    let* never_called = decode_list "never_called" decode_tool_names never_items in
    let decode_tool json =
      let* name = required_nonblank_string json "name" in
      let* description = optional_nonblank_string json "description" in
      let calls, failure_rate_pct =
        match rows_named name ~names_of:(fun (r : tool_usage_row) -> r.names) called with
        | _ :: _ as rows ->
            let calls =
              List.fold_left (fun acc (r : tool_usage_row) -> acc + r.call_count) 0 rows
            in
            let failures =
              List.fold_left
                (fun acc (r : tool_usage_row) -> acc + r.failure_count)
                0 rows
            in
            ( Observed.value ~observed_at calls,
              if calls > 0 then
                Observed.value ~observed_at
                  (100.0 *. float_of_int failures /. float_of_int calls)
              else Observed.absent )
        | [] -> (
            match rows_named name ~names_of:Fun.id never_called with
            | _ :: _ -> (Observed.value ~observed_at 0, Observed.absent)
            | [] -> (Observed.unreported, Observed.unreported))
      in
      Ok { name; description; calls; failure_rate_pct }
    in
    let* tools = decode_list "tools" decode_tool tool_items in
    Ok (Tools_ready tools)

type tool_series_failure_classes = {
  dependency_unavailable : int;
  policy_rejection : int;
  runtime_failure : int;
  workflow_rejection : int;
  operator_cancelled : int;
  unclassified : int;
}

type tool_series_summary = {
  tool_filter : string option;
  total_calls : int;
  total_failures : int;
  total_deferred : int;
  p50_ms : float option;
  p95_ms : float option;
  failure_classes : tool_series_failure_classes;
  series : tool_series;
}

let decode_tool_series_summary json =
  let* series = decode_tool_series json in
  let* _, body = unwrap_v2_or_raw json in
  let* tool_filter = optional_nonblank_string body "tool" in
  let int_or obj k =
    match optional_int_field obj k with Ok (Some n) -> max 0 n | Ok None | Error _ -> 0
  in
  let total_calls, total_failures, total_deferred, p50_ms, p95_ms, failure_classes =
    match optional_object_field body "total" with
    | Ok (Some tot) ->
        let fc =
          match optional_object_field tot "failure_classes" with
          | Ok (Some obj) ->
              {
                dependency_unavailable = int_or obj "dependency_unavailable";
                policy_rejection = int_or obj "policy_rejection";
                runtime_failure = int_or obj "runtime_failure";
                workflow_rejection = int_or obj "workflow_rejection";
                operator_cancelled = int_or obj "operator_cancelled";
                unclassified = int_or tot "failure_unclassified_count";
              }
          | Ok None | Error _ ->
              {
                dependency_unavailable = 0;
                policy_rejection = 0;
                runtime_failure = 0;
                workflow_rejection = 0;
                operator_cancelled = 0;
                unclassified = int_or tot "failure_unclassified_count";
              }
        in
        let p50 =
          match optional_finite_float tot "p50_ms" with
          | Ok v -> v
          | Error _ -> None
        in
        let p95 =
          match optional_finite_float tot "p95_ms" with
          | Ok v -> v
          | Error _ -> None
        in
        ( int_or tot "call_count",
          int_or tot "failure_count",
          int_or tot "deferred_count",
          p50,
          p95,
          fc )
    | Ok None | Error _ ->
        let c, f, d, p95 =
          List.fold_left
            (fun (c, f, d, pmax) (b : tool_series_bucket) ->
              match b.activity with
              | Series_idle -> (c, f, d, pmax)
              | Series_active { calls; failures; deferred; p95_ms } ->
                  let next_p =
                    match pmax with
                    | None -> Some p95_ms
                    | Some cur -> Some (Float.max cur p95_ms)
                  in
                  (c + calls, f + failures, d + deferred, next_p))
            (0, 0, 0, None) series.buckets
        in
        ( c,
          f,
          d,
          None,
          p95,
          {
            dependency_unavailable = 0;
            policy_rejection = 0;
            runtime_failure = 0;
            workflow_rejection = 0;
            operator_cancelled = 0;
            unclassified = 0;
          } )
  in
  Ok
    {
      tool_filter;
      total_calls;
      total_failures;
      total_deferred;
      p50_ms;
      p95_ms;
      failure_classes;
      series;
    }

type tool_catalog_entry = {
  name : string;
  description : string option;
  public_names : string list;
  calls_count : int Observed.t;
  failure_count : int;
  failure_rate_pct : float Observed.t;
  p95_ms : float option;
  direct_call_allowed : bool option;
  surfaces : string list;
  domain : string;
  family : string;
  doc_refs : string list;
}

type effective_keeper_tool_entry = {
  name : string;
  origin : string;
}

type effective_keeper_surface =
  | Keeper_surface_unavailable of {
      keeper_name : string;
      reason : string;
      detail : string;
    }
  | Keeper_surface_available of {
      keeper_name : string;
      runtime_id : string;
      tool_delivery : string;
      tool_surface_bytes : int;
      skill_tool_surface_bytes : int;
      skill_discovery_bytes : int;
      skill_body_bytes : int;
      tool_surface_sha256 : string option;
      tools : effective_keeper_tool_entry list;
      skills_left_out : string list;
      lane_addon_conflicts : string list;
    }

type tools_dashboard_snapshot = {
  entries : tool_catalog_entry list;
  total_calls : int;
  distinct_tools_called : int;
  registered_count : int;
  effective_keeper_surface : effective_keeper_surface option;
  volume_gc_summary : string option;
  keeper_cleanup_summary : string option;
}

let classify_tool_domain_family name =
  let lc = String.lowercase_ascii (String.trim name) in
  let has p = String.starts_with ~prefix:p lc in
  if has "masc_board" || has "board_" then ("board", "board")
  else if has "masc_goal" || has "masc_task" || has "masc_schedule" || has "masc_verify" || has "masc_verif" || has "masc_plan" then
    let fam =
      if has "masc_goal" then "goals"
      else if has "masc_task" then "tasks"
      else if has "masc_schedule" then "schedules"
      else "verification"
    in
    ("work", fam)
  else if has "masc_run" || has "execute" || has "bash" || has "shell" || has "read" || has "write" || has "edit" || has "grep" || has "glob" || has "web_" || has "browser_" then
    let fam =
      if has "browser_" || has "web_" then "web & browser"
      else if has "read" || has "write" || has "edit" || has "grep" || has "glob" then "files"
      else "exec"
    in
    ("run", fam)
  else if has "keeper_" && (has "keeper_memory" || has "keeper_journal" || has "keeper_note" || has "keeper_self") then
    ("keeper self", "memory & reflection")
  else if has "keeper_" || has "masc_keeper" then ("keeper ops", "keeper")
  else if has "masc_" then
    let rest = String.sub lc 5 (String.length lc - 5) in
    let fam =
      match String.index_opt rest '_' with
      | Some idx when idx > 0 -> String.sub rest 0 idx
      | Some _ | None -> rest
    in
    ("system", fam)
  else ("unsorted", "general")

type usage_row = {
  u_name : string;
  u_public_names : string list;
  u_calls : int;
  u_failures : int;
  u_p95_ms : float option;
}

let decode_usage_row json =
  let* u_name = required_nonblank_string json "name" in
  let* u_public_names = optional_string_list json "public_names" in
  let* u_calls = required_nonnegative_int_field json "call_count" in
  let* fail_opt = optional_int_field json "failure_count" in
  let u_failures = max 0 (Option.value ~default:0 fail_opt) in
  let* u_p95_ms = optional_finite_float json "p95_ms" in
  Ok { u_name; u_public_names; u_calls; u_failures; u_p95_ms }

let decode_effective_keeper_surface json =
  match json with
  | `Null -> Ok None
  | `Assoc _ -> (
      let* status = required_nonblank_string json "status" in
      match status with
      | "unavailable" ->
          let* keeper_name = required_nonblank_string json "keeper_name" in
          let* reason = optional_nonblank_string json "reason" in
          let* detail = optional_nonblank_string json "detail" in
          Ok
            (Some
               (Keeper_surface_unavailable
                  {
                    keeper_name;
                    reason = Option.value ~default:"unavailable" reason;
                    detail = Option.value ~default:"" detail;
                  }))
      | "available" ->
          let* keeper_name = required_nonblank_string json "keeper_name" in
          let* runtime_id_opt = optional_nonblank_string json "runtime_id" in
          let runtime_id = Option.value ~default:"" runtime_id_opt in
          let tool_delivery =
            match member "tool_delivery" json with
            | `String s -> s
            | `Assoc _ as obj -> (
                match optional_nonblank_string obj "status" with
                | Ok (Some st) -> (
                    match optional_nonblank_string obj "reason" with
                    | Ok (Some r) -> Printf.sprintf "%s (%s)" st r
                    | Ok None | Error _ -> st)
                | Ok None | Error _ -> (
                    match optional_nonblank_string obj "mode" with
                    | Ok (Some m) -> m
                    | Ok None | Error _ -> (
                        match optional_nonblank_string obj "kind" with
                        | Ok (Some k) -> k
                        | Ok None | Error _ -> "configured")))
            | _ -> "unknown"
          in
          let int_or k =
            match optional_int_field json k with
            | Ok (Some n) -> max 0 n
            | Ok None | Error _ -> 0
          in
          let* tool_surface_sha256 =
            optional_nonblank_string json "tool_surface_sha256"
          in
          let* raw_tools = optional_list_field json "tools" in
          let tools =
            List.filter_map
              (fun item ->
                match optional_nonblank_string item "name" with
                | Ok (Some name) ->
                    let origin =
                      match member "origin" item with
                      | `String s -> s
                      | `Assoc _ as obj -> (
                          match optional_nonblank_string obj "kind" with
                          | Ok (Some k) -> k
                          | Ok None | Error _ -> Yojson.Safe.to_string obj)
                      | _ -> "descriptor"
                    in
                    Some { name; origin }
                | Ok None | Error _ -> None)
              raw_tools
          in
          let* skills_left_out = optional_string_list json "skills_left_out" in
          let* raw_conflicts = optional_list_field json "lane_addon_conflicts" in
          let lane_addon_conflicts =
            List.filter_map
              (fun c ->
                match optional_nonblank_string c "name" with
                | Ok (Some n) -> Some n
                | Ok None | Error _ -> None)
              raw_conflicts
          in
          Ok
            (Some
               (Keeper_surface_available
                  {
                    keeper_name;
                    runtime_id;
                    tool_delivery;
                    tool_surface_bytes = int_or "tool_surface_bytes";
                    skill_tool_surface_bytes = int_or "skill_tool_surface_bytes";
                    skill_discovery_bytes = int_or "skill_discovery_bytes";
                    skill_body_bytes = int_or "skill_body_bytes";
                    tool_surface_sha256;
                    tools;
                    skills_left_out;
                    lane_addon_conflicts;
                  }))
      | other -> Error ("unknown effective_keeper_surface status: " ^ other))
  | bad -> field_type_error "effective_keeper_surface" "object or null" bad

let decode_tools_dashboard ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* inv_opt = optional_object_field body "tool_inventory" in
  let* usage_opt = optional_object_field body "tool_usage" in
  let* eff_surface =
    if has_field body "effective_keeper_surface" then
      decode_effective_keeper_surface (member "effective_keeper_surface" body)
    else Ok None
  in
  let summary_of_obj keys =
    let rec find = function
      | [] -> None
      | key :: rest -> (
          match optional_object_field body key with
          | Ok (Some obj) -> (
              match optional_nonblank_string obj "outcome" with
              | Ok (Some s) -> Some s
              | Ok None | Error _ -> (
                  match optional_nonblank_string obj "status" with
                  | Ok (Some s) -> Some s
                  | Ok None | Error _ -> (
                      match optional_nonblank_string obj "state" with
                      | Ok (Some s) -> Some s
                      | Ok None | Error _ -> (
                          match optional_nonblank_string obj "kind" with
                          | Ok (Some s) -> Some s
                          | Ok None | Error _ -> Some "reported"))))
          | Ok None | Error _ -> find rest)
    in
    find keys
  in
  let volume_gc_summary =
    summary_of_obj [ "sandbox_volume_gc_report"; "volume_gc_periodic" ]
  in
  let keeper_cleanup_summary =
    summary_of_obj [ "keeper_cleanup"; "keeper_cleanup_status" ]
  in
  match inv_opt with
  | Some inv ->
      let* raw_tools = required_list_field inv "tools" in
      let* usage_rows, total_calls, distinct_tools_called, registered_count =
        match usage_opt with
        | None -> Ok ([], 0, 0, List.length raw_tools)
        | Some u ->
            let* by_tool_raw = optional_list_field u "by_tool" in
            let* by_tool = decode_list "by_tool" decode_usage_row by_tool_raw in
            let* tc = optional_int_field u "total_calls" in
            let* dc = optional_int_field u "distinct_tools_called" in
            let* rc = optional_int_field u "registered_count" in
            Ok
              ( by_tool,
                Option.value ~default:0 tc,
                Option.value ~default:(List.length by_tool) dc,
                Option.value ~default:(List.length raw_tools) rc )
      in
      let usage_tbl = Hashtbl.create (max 16 (List.length usage_rows * 2)) in
      List.iter
        (fun (u : usage_row) ->
          Hashtbl.replace usage_tbl u.u_name u;
          List.iter (fun pn -> Hashtbl.replace usage_tbl pn u) u.u_public_names)
        usage_rows;
      let decode_inv_item item =
        let* name = required_nonblank_string item "name" in
        let* description = optional_nonblank_string item "description" in
        let* direct_call_allowed = optional_bool_field item "direct_call_allowed" in
        let* surfaces = optional_string_list item "surfaces" in
        let* doc_refs = optional_string_list item "doc_refs" in
        let* domain_opt = optional_nonblank_string item "domain" in
        let* family_opt = optional_nonblank_string item "family" in
        let def_dom, def_fam = classify_tool_domain_family name in
        let domain = Option.value ~default:def_dom domain_opt in
        let family = Option.value ~default:def_fam family_opt in
        let calls_count, failure_count, failure_rate_pct, p95_ms, public_names =
          match Hashtbl.find_opt usage_tbl name with
          | Some u ->
              let rate =
                if u.u_calls > 0 then
                  float_of_int u.u_failures *. 100.0 /. float_of_int u.u_calls
                else 0.0
              in
              ( Observed.value ~observed_at u.u_calls,
                u.u_failures,
                Observed.value ~observed_at rate,
                u.u_p95_ms,
                u.u_public_names )
          | None ->
              ( Observed.value ~observed_at 0,
                0,
                Observed.value ~observed_at 0.0,
                None,
                [] )
        in
        Ok
          {
            name;
            description;
            public_names;
            calls_count;
            failure_count;
            failure_rate_pct;
            p95_ms;
            direct_call_allowed;
            surfaces;
            domain;
            family;
            doc_refs;
          }
      in
      let* entries = decode_list "tool_inventory.tools" decode_inv_item raw_tools in
      Ok
        {
          entries;
          total_calls;
          distinct_tools_called;
          registered_count;
          effective_keeper_surface = eff_surface;
          volume_gc_summary;
          keeper_cleanup_summary;
        }
  | None ->
      (* Graceful fallback for legacy flat "tools" fixture *)
      let* items = required_list_field body "tools" in
      let decode_flat item =
        let* name = required_nonblank_string item "name" in
        let* description = optional_nonblank_string item "description" in
        let* calls_count = observed_int ~observed_at item "calls_24h" in
        let* failure_rate_pct = observed_float ~observed_at item "failure_rate_pct" in
        let* p95_ms = optional_finite_float item "p95_ms" in
        let* direct_call_allowed = optional_bool_field item "direct_call_allowed" in
        let* surfaces = optional_string_list item "surfaces" in
        let domain, family = classify_tool_domain_family name in
        let failure_count =
          match Observed.to_option calls_count, Observed.to_option failure_rate_pct with
          | Some c, Some pct -> int_of_float (Float.round (float_of_int c *. pct /. 100.0))
          | _ -> 0
        in
        Ok
          {
            name;
            description;
            public_names = [];
            calls_count;
            failure_count;
            failure_rate_pct;
            p95_ms;
            direct_call_allowed;
            surfaces;
            domain;
            family;
            doc_refs = [];
          }
      in
      let* entries = decode_list "tools" decode_flat items in
      let total_calls =
        List.fold_left
          (fun acc (e : tool_catalog_entry) ->
            acc + Option.value ~default:0 (Observed.to_option e.calls_count))
          0 entries
      in
      Ok
        {
          entries;
          total_calls;
          distinct_tools_called = List.length entries;
          registered_count = List.length entries;
          effective_keeper_surface = eff_surface;
          volume_gc_summary;
          keeper_cleanup_summary;
        }

type skill_surface_entry = {
  reference : string;
  kind : string;
  summary : string option;
  error : string option;
}

type skills_snapshot = {
  state : string;
  snapshot_revision : string option;
  surfaces : skill_surface_entry list;
  shadows : string list;
  rejections : string list;
}

let string_of_skill_identity obj =
  match optional_nonblank_string obj "name" with
  | Ok (Some name) -> (
      match optional_nonblank_string obj "package_id" with
      | Ok (Some pkg) when not (String.equal pkg name) ->
          Printf.sprintf "%s (%s)" name pkg
      | Ok _ | Error _ -> name)
  | Ok None | Error _ -> (
      match optional_nonblank_string obj "package_id" with
      | Ok (Some pkg) -> pkg
      | Ok None | Error _ -> (
          match optional_nonblank_string obj "source_id" with
          | Ok (Some src) -> src
          | Ok None | Error _ -> "skill"))

let string_of_ref_or_obj json =
  match json with
  | `String s -> s
  | `Assoc _ -> (
      match optional_object_field json "identity" with
      | Ok (Some id_obj) -> string_of_skill_identity id_obj
      | Ok None | Error _ -> (
          match optional_nonblank_string json "name" with
          | Ok (Some n) -> n
          | Ok None | Error _ -> (
              match optional_nonblank_string json "identity" with
              | Ok (Some id) -> id
              | Ok None | Error _ -> (
                  match optional_nonblank_string json "package_id" with
                  | Ok (Some pkg) -> (
                      match optional_object_field json "reason" with
                      | Ok (Some r_obj) -> (
                          match optional_nonblank_string r_obj "kind" with
                          | Ok (Some rk) -> Printf.sprintf "%s: %s" pkg rk
                          | Ok None | Error _ -> pkg)
                      | Ok None | Error _ -> pkg)
                  | Ok None | Error _ -> (
                      match optional_nonblank_string json "source_id" with
                      | Ok (Some src) -> (
                          match optional_object_field json "reason" with
                          | Ok (Some r_obj) -> (
                              match optional_nonblank_string r_obj "kind" with
                              | Ok (Some rk) -> Printf.sprintf "%s: %s" src rk
                              | Ok None | Error _ -> src)
                          | Ok None | Error _ -> src)
                      | Ok None | Error _ -> (
                          match optional_nonblank_string json "id" with
                          | Ok (Some id) -> id
                          | Ok None | Error _ -> "entry"))))))
  | other -> Yojson.Safe.to_string other

let decode_skill_profile_summary item =
  let extract_from obj =
    match optional_nonblank_string obj "summary" with
    | Ok (Some s) -> Some s
    | Ok None | Error _ -> (
        match optional_nonblank_string obj "description" with
        | Ok (Some d) -> Some d
        | Ok None | Error _ ->
            let exec_s =
              match optional_nonblank_string obj "execution" with
              | Ok v -> v
              | Error _ -> None
            in
            let act_s =
              match optional_nonblank_string obj "activation_tool" with
              | Ok v -> v
              | Error _ -> None
            in
            let bytes_s =
              match optional_object_field obj "context" with
              | Ok (Some ctx) -> (
                  match optional_int_field ctx "body_bytes" with
                  | Ok (Some b) -> Some (Printf.sprintf "%dB" b)
                  | Ok None | Error _ -> None)
              | Ok None | Error _ -> None
            in
            let parts = List.filter_map Fun.id [ exec_s; act_s; bytes_s ] in
            if parts = [] then None else Some (String.concat " · " parts))
  in
  match optional_object_field item "profile" with
  | Ok (Some p) -> (
      match extract_from p with
      | Some _ as hit -> hit
      | None -> extract_from item)
  | Ok None | Error _ -> extract_from item

let decode_skills_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* state = required_nonblank_string body "state" in
  let* snap_opt = optional_object_field body "snapshot" in
  let snapshot_revision, shadows, rejections =
    match snap_opt with
    | None -> (None, [], [])
    | Some s ->
        let rev =
          match optional_nonblank_string s "snapshot_revision" with
          | Ok v -> v
          | Error _ -> None
        in
        let sh =
          match optional_list_field s "shadows" with
          | Ok xs -> List.map string_of_ref_or_obj xs
          | Error _ -> []
        in
        let rej =
          match optional_list_field s "rejections" with
          | Ok xs -> List.map string_of_ref_or_obj xs
          | Error _ -> []
        in
        (rev, sh, rej)
  in
  let* raw_surfaces = optional_list_field body "surfaces" in
  let surfaces =
    List.filter_map
      (fun item ->
        let kind_opt =
          match optional_nonblank_string item "kind" with
          | Ok (Some k) -> Some k
          | Ok None | Error _ -> (
              match optional_object_field item "profile" with
              | Ok (Some p) -> (
                  match optional_nonblank_string p "kind" with
                  | Ok (Some k) -> Some k
                  | Ok None | Error _ -> (
                      match optional_nonblank_string p "execution" with
                      | Ok v -> v
                      | Error _ -> None))
              | Ok None | Error _ -> None)
        in
        match kind_opt with
        | Some kind ->
            let reference =
              if has_field item "reference" then
                string_of_ref_or_obj (member "reference" item)
              else "unknown"
            in
            let summary = decode_skill_profile_summary item in
            let error =
              match optional_nonblank_string item "error" with
              | Ok v -> v
              | Error _ -> None
            in
            Some { reference; kind; summary; error }
        | None -> None)
      raw_surfaces
  in
  Ok { state; snapshot_revision; surfaces; shadows; rejections }

type connector_connection =
  | Connector_connected
  | Connector_connected_unavailable
  | Connector_disconnected
  | Connector_offline
  | Connector_stale

type connector_binding = {
  channel_id : string;
  keeper_name : string;
}

type connector_row = {
  connector_id : string;
  display_name : string;
  connection : connector_connection;
  channel : string option;
  error : string option;
  binding_count : int;
  configured_bindings : connector_binding list;
}

let decode_connector_binding json =
  match optional_nonblank_string json "channel_id" with
  | Ok (Some channel_id) ->
      let keeper_name =
        match optional_nonblank_string json "keeper_name" with
        | Ok (Some k) -> k
        | Ok None | Error _ -> ""
      in
      Some { channel_id; keeper_name }
  | Ok None | Error _ -> None

let decode_connector_row json =
  let* connector_id = required_nonblank_string json "connector_id" in
  let* display_name = required_nonblank_string json "display_name" in
  let* status = required_nonblank_string json "status" in
  let* available = required_bool_field json "available" in
  let* connected = required_bool_field json "connected" in
  let* connection =
    match (status, available, connected) with
    | "connected", true, true -> Ok Connector_connected
    | "offline", false, true -> Ok Connector_connected_unavailable
    | "disconnected", true, false -> Ok Connector_disconnected
    | "offline", false, false -> Ok Connector_offline
    | "stale", true, false -> Ok Connector_stale
    | _ ->
        Error
          (Printf.sprintf
             "connector %S status %S contradicts available=%b connected=%b"
             connector_id status available connected)
  in
  let* channel = optional_nonblank_string json "channel" in
  let* error = optional_nonblank_string json "error" in
  let* bindings_raw = optional_list_field json "configured_bindings" in
  let configured_bindings =
    List.filter_map decode_connector_binding bindings_raw
  in
  Ok
    {
      connector_id;
      display_name;
      connection;
      channel;
      error;
      binding_count = List.length bindings_raw;
      configured_bindings;
    }

let decode_connectors json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "connectors" in
  decode_list "connectors" decode_connector_row items

(* [handle_bind_for_connector] reads exactly these two body fields and refuses
   a blank one. *)
let encode_connector_bind ~channel_id ~keeper_name =
  `Assoc
    [ ("channel_id", `String channel_id); ("keeper_name", `String keeper_name) ]

type browser_space_ref = {
  space_id : int;
  space_name : string;
}

type browser_interaction_row = {
  request_id : string;
  actor : string option;
  action : string;
  tab_id : int option;
  phase : string;
}

type browser_settled_activity = {
  work : browser_interaction_row;
  outcome : string;
}

type browser_client_row = {
  client_id : string;
  browser : string;
  version : string;
  engine_version : string;
  transport : string;
  space : browser_space_ref option;
  ownership : string option;
  presence_state : string option;
  presence_reason : string option;
  interactions : browser_interaction_row list;
  last_activities : browser_settled_activity list;
}

type browser_inventory_issue = {
  kind : string;
  instance_id : string option;
  client_id : string option;
  space : string option;
  space_id : int option;
  message : string;
}

type browser_lane_status = {
  ok : bool;
  available : bool;
  inventory_complete : bool;
  client_count : int;
  issue_count : int;
  automatic_browse_ok : bool;
  detail : string option;
  clients : browser_client_row list;
  issues : browser_inventory_issue list;
}

let decode_browser_interaction json =
  let* request_id = required_nonblank_string json "requestId" in
  let* actor = optional_nonblank_string json "actor" in
  let* action = required_nonblank_string json "action" in
  let* tab_id = optional_int_field json "tabId" in
  let* phase = required_nonblank_string json "phase" in
  Ok { request_id; actor; action; tab_id; phase }

let decode_browser_settled_activity json =
  let* work_json = required_object_field json "work" in
  let* work = decode_browser_interaction work_json in
  let* outcome = required_nonblank_string json "outcome" in
  Ok { work; outcome }

let decode_browser_client_row json =
  let* client_id = required_nonblank_string json "clientId" in
  let* browser_opt = optional_nonblank_string json "browser" in
  let* version_opt = optional_nonblank_string json "version" in
  let* engine_opt = optional_nonblank_string json "engineVersion" in
  let* transport_opt = optional_nonblank_string json "transport" in
  let* space_opt = optional_object_field json "space" in
  let* space =
    match space_opt with
    | None -> Ok None
    | Some sp ->
        let* space_id = required_int_field sp "id" in
        let* space_name = required_nonblank_string sp "name" in
        Ok (Some { space_id; space_name })
  in
  let* obs_opt = optional_object_field json "spaceObservation" in
  let* ownership_obs, space_from_obs =
    match obs_opt with
    | None -> Ok (None, None)
    | Some obs ->
        let* own = optional_nonblank_string obs "ownership" in
        let* sp_id = optional_int_field obs "spaceId" in
        let* sp_name = optional_nonblank_string obs "spaceName" in
        let sp =
          match sp_id, sp_name with
          | Some space_id, Some space_name -> Some { space_id; space_name }
          | _ -> None
        in
        Ok (own, sp)
  in
  let* ownership_top = optional_nonblank_string json "ownership" in
  let ownership =
    match ownership_obs with Some _ -> ownership_obs | None -> ownership_top
  in
  let space = match space with Some _ -> space | None -> space_from_obs in
  let* pres_opt =
    match optional_object_field json "spacePresence" with
    | Ok (Some _ as p) -> Ok p
    | Ok None -> optional_object_field json "presence"
    | Error _ as err -> err
  in
  let* presence_state, presence_reason =
    match pres_opt with
    | None -> Ok (None, None)
    | Some pres ->
        let* st = optional_nonblank_string pres "state" in
        let* reason_obj = optional_object_field pres "reason" in
        let* reason_str =
          match reason_obj with
          | None -> Ok None
          | Some ro -> (
              let* rk = optional_nonblank_string ro "kind" in
              let* rd = optional_nonblank_string ro "detail" in
              match rk, rd with
              | Some k, Some d -> Ok (Some (k ^ ": " ^ d))
              | Some k, None -> Ok (Some k)
              | None, Some d -> Ok (Some d)
              | None, None -> Ok None)
        in
        Ok (st, reason_str)
  in
  let* interactions_raw = optional_list_field json "interactions" in
  let* interactions =
    decode_list "interactions" decode_browser_interaction interactions_raw
  in
  let* settled_raw = optional_list_field json "lastActivities" in
  let* last_activities =
    decode_list "lastActivities" decode_browser_settled_activity settled_raw
  in
  Ok
    {
      client_id;
      browser = Option.value ~default:"browser" browser_opt;
      version = Option.value ~default:"" version_opt;
      engine_version = Option.value ~default:"" engine_opt;
      transport = Option.value ~default:"" transport_opt;
      space;
      ownership;
      presence_state;
      presence_reason;
      interactions;
      last_activities;
    }

let decode_browser_inventory_issue json =
  let* kind_opt = optional_nonblank_string json "kind" in
  let kind = Option.value ~default:"issue" kind_opt in
  let* instance_id = optional_nonblank_string json "instanceId" in
  let* client_id = optional_nonblank_string json "clientId" in
  let* space = optional_nonblank_string json "space" in
  let* space_id = optional_int_field json "spaceId" in
  let* msg_opt = optional_nonblank_string json "message" in
  let instances_list =
    match optional_list_field json "instances" with
    | Ok xs ->
        List.filter_map
          (function `String s when String.trim s <> "" -> Some s | _ -> None)
          xs
    | Error _ -> []
  in
  let message =
    match msg_opt with
    | Some m -> m
    | None -> (
        match kind, instance_id, space, space_id, client_id with
        | "ego_user_owned_space", Some inst, Some sp, _, _ ->
            Printf.sprintf "%s: space %s is user-owned" inst sp
        | "ego_space_missing", Some inst, Some sp, Some sid, _ ->
            Printf.sprintf "%s: space #%d (%s) missing" inst sid sp
        | "duplicate_client", _, _, _, Some cid ->
            Printf.sprintf "duplicate client %s (%s)" cid
              (String.concat ", " instances_list)
        | "duplicate_ego_space", _, _, Some sid, _ ->
            Printf.sprintf "duplicate space #%d (%s)" sid
              (String.concat ", " instances_list)
        | _ -> (
            match instance_id with
            | Some inst -> Printf.sprintf "%s: %s" inst kind
            | None -> kind))
  in
  Ok { kind; instance_id; client_id; space; space_id; message }

let decode_browser_lane json =
  let* _, body = unwrap_v2_or_raw json in
  let* ok = required_bool_field body "ok" in
  if not ok then
    let* err = optional_nonblank_string body "error" in
    Ok
      {
        ok = false;
        available = false;
        inventory_complete = false;
        client_count = 0;
        issue_count = 0;
        automatic_browse_ok = false;
        detail = err;
        clients = [];
        issues = [];
      }
  else
    let* data = required_object_field body "data" in
    let* clients_raw = required_list_field data "clients" in
    let* clients = decode_list "clients" decode_browser_client_row clients_raw in
    let* issues_raw = required_list_field data "inventoryIssues" in
    let* issues =
      decode_list "inventoryIssues" decode_browser_inventory_issue issues_raw
    in
    let* inventory_complete = required_bool_field data "inventoryComplete" in
    let* automatic = required_object_field data "automatic" in
    let* browse = required_object_field automatic "browse" in
    let* automatic_browse_ok = required_bool_field browse "ok" in
    let* detail =
      if automatic_browse_ok then Ok None
      else
        match optional_object_field browse "error" with
        | Ok (Some err_obj) -> optional_nonblank_string err_obj "message"
        | Ok None -> Ok None
        | Error _ as err -> err
    in
    let client_count = List.length clients in
    Ok
      {
        ok = true;
        available = client_count > 0 || automatic_browse_ok;
        inventory_complete;
        client_count;
        issue_count = List.length issues;
        automatic_browse_ok;
        detail;
        clients;
        issues;
      }

type browser_tab_origin =
  | Tab_origin_agent
  | Tab_origin_unknown

type browser_tab_row = {
  id : int;
  title : string;
  url : string;
  active : bool;
  window_id : int option;
  opened_by : browser_tab_origin option;
  label : string option;
  dialog_present : bool;
  dialog_kind : string option;
}

type browser_tabs_response = {
  client_id : string option;
  tabs : browser_tab_row list;
  complete : bool;
  unavailable_count : int;
  error : string option;
}

let encode_browser_tabs_request ~client_id =
  `Assoc [ ("lane", `String "live"); ("clientId", `String client_id) ]

let decode_browser_tab_row json =
  let* id = required_int_field json "id" in
  let* title = required_string_field json "title" in
  let* url = required_string_field json "url" in
  let* active = required_bool_field json "active" in
  let* window_id = optional_int_field json "windowId" in
  let* ego_page_opt = optional_object_field json "egoPage" in
  let* opened_by, label =
    match ego_page_opt with
    | None -> Ok (None, None)
    | Some ep ->
        let* lbl = optional_nonblank_string ep "label" in
        let* ob_raw = optional_nonblank_string ep "openedBy" in
        let ob =
          match ob_raw with
          | Some "agent" -> Some Tab_origin_agent
          | Some _ -> Some Tab_origin_unknown
          | None -> None
        in
        Ok (ob, lbl)
  in
  let* dialog_opt = optional_object_field json "dialog" in
  let* dialog_present, dialog_kind =
    match dialog_opt with
    | None -> Ok (false, None)
    | Some dlg ->
        let* dk = optional_nonblank_string dlg "type" in
        Ok (true, dk)
  in
  Ok
    {
      id;
      title;
      url;
      active;
      window_id;
      opened_by;
      label;
      dialog_present;
      dialog_kind;
    }

let decode_browser_tabs_response json =
  let* _, body = unwrap_v2_or_raw json in
  let* ok_opt = optional_bool_field body "ok" in
  match ok_opt with
  | Some false ->
      let* error = optional_nonblank_string body "error" in
      Ok
        {
          client_id = None;
          tabs = [];
          complete = false;
          unavailable_count = 0;
          error;
        }
  | Some true | None ->
      let* data =
        match optional_object_field body "data" with
        | Ok (Some d) -> Ok d
        | Ok None -> Ok body
        | Error _ as err -> err
      in
      let* client_id = optional_nonblank_string data "clientId" in
      let* tabs_raw = required_list_field data "tabs" in
      let* tabs = decode_list "tabs" decode_browser_tab_row tabs_raw in
      let* complete_opt = optional_bool_field data "complete" in
      let complete = Option.value ~default:true complete_opt in
      let* unavail_raw = optional_list_field data "unavailableTabs" in
      Ok
        {
          client_id;
          tabs;
          complete;
          unavailable_count = List.length unavail_raw;
          error = None;
        }

type addon_runtime_presence =
  | Addon_live
  | Addon_retained

type addon_phase =
  | Addon_attached
  | Addon_observing
  | Addon_detaching
  | Addon_detached
  | Addon_failed
  | Addon_phase_other of string

type addon_declaration = {
  id : string;
  source_path : string;
  enabled : bool;
  source_revision : string;
  desired_revision : string;
  applied_revision : string option;
  instance_id : string option;
  application_kind : string;
  application_messages : string list;
  ui_category : string option;
}

type addon_instance = {
  runtime_presence : addon_runtime_presence;
  instance_id : string;
  addon_id : string;
  title : string;
  revision : string;
  phase : addon_phase;
  execution_kind : string option;
  resolved_image : string option;
  observation_seq : int;
  rows_count : int;
  observation_pending : bool;
  visibility_kind : string option;
  visibility_keeper : string option;
  host_cycles : int option;
  host_waiting_count : int;
  host_issue_kind : string option;
  action_names : string list;
  config_declaration_id : string option;
}

type lane_addons_issue = {
  source_path : string;
  id : string option;
  message : string;
}

type lane_addons_snapshot = {
  configuration_complete : bool;
  declarations : addon_declaration list;
  instances : addon_instance list;
  issues : lane_addons_issue list;
}

let decode_addon_phase = function
  | "attached" -> Addon_attached
  | "observing" -> Addon_observing
  | "detaching" -> Addon_detaching
  | "detached" -> Addon_detached
  | "failed" -> Addon_failed
  | other -> Addon_phase_other other

let decode_addon_declaration json =
  let* id = required_nonblank_string json "id" in
  let* source_path_opt = optional_nonblank_string json "source_path" in
  let source_path = Option.value ~default:"" source_path_opt in
  let* enabled = required_bool_field json "enabled" in
  let* src_rev_opt = optional_nonblank_string json "source_revision" in
  let* desired_rev_opt = optional_nonblank_string json "desired_revision" in
  let* applied_revision = optional_nonblank_string json "applied_revision" in
  let* instance_id = optional_nonblank_string json "instance_id" in
  let* app_opt = optional_object_field json "application" in
  let* application_kind, application_messages =
    match app_opt with
    | None -> Ok ("unknown", [])
    | Some app ->
        let* kind_opt = optional_nonblank_string app "kind" in
        let msgs =
          match optional_list_field app "messages" with
          | Ok xs ->
              List.filter_map
                (function
                  | `String s when String.trim s <> "" -> Some s | _ -> None)
                xs
          | Error _ -> []
        in
        Ok (Option.value ~default:"unknown" kind_opt, msgs)
  in
  let* ui_category = optional_nonblank_string json "ui_category" in
  Ok
    {
      id;
      source_path;
      enabled;
      source_revision = Option.value ~default:"" src_rev_opt;
      desired_revision = Option.value ~default:"" desired_rev_opt;
      applied_revision;
      instance_id;
      application_kind;
      application_messages;
      ui_category;
    }

let extract_action_names_from_schema schema_json =
  let collect_one = function
    | `Assoc fields -> (
        match List.assoc_opt "properties" fields with
        | Some (`Assoc props) -> (
            match List.assoc_opt "action" props with
            | Some (`Assoc af) -> (
                match List.assoc_opt "enum" af with
                | Some (`List items) ->
                    List.filter_map
                      (function `String s -> Some s | _ -> None)
                      items
                | _ -> (
                    match List.assoc_opt "const" af with
                    | Some (`String s) -> [ s ]
                    | _ -> List.map fst props))
            | _ -> List.map fst props)
        | _ -> (
            match List.assoc_opt "title" fields with
            | Some (`String s) when String.trim s <> "" -> [ s ]
            | _ -> []))
    | _ -> []
  in
  let raw =
    match schema_json with
    | `Assoc fields -> (
        let direct = collect_one schema_json in
        let from_one_of =
          match List.assoc_opt "oneOf" fields with
          | Some (`List branches) -> List.concat_map collect_one branches
          | _ -> []
        in
        let from_any_of =
          match List.assoc_opt "anyOf" fields with
          | Some (`List branches) -> List.concat_map collect_one branches
          | _ -> []
        in
        direct @ from_one_of @ from_any_of)
    | _ -> []
  in
  let seen = Hashtbl.create 8 in
  List.filter
    (fun s ->
      let t = String.trim s in
      if String.equal t "" || Hashtbl.mem seen t then false
      else begin
        Hashtbl.add seen t ();
        true
      end)
    raw

let decode_addon_instance json =
  let* presence_raw = optional_nonblank_string json "runtime_presence" in
  let* runtime_presence =
    match presence_raw with
    | None | Some "live" -> Ok Addon_live
    | Some "retained" -> Ok Addon_retained
    | Some other -> Error ("unknown addon runtime_presence: " ^ other)
  in
  let* instance_id = required_nonblank_string json "instance_id" in
  let* addon_id = required_nonblank_string json "addon_id" in
  let* title_opt = optional_nonblank_string json "title" in
  let title = Option.value ~default:addon_id title_opt in
  let* rev_opt = optional_nonblank_string json "revision" in
  let* phase =
    match member "phase" json with
    | `Assoc _ as obj ->
        let* kind = required_nonblank_string obj "kind" in
        Ok (decode_addon_phase (String.lowercase_ascii kind))
    | `String s when not (String.equal (String.trim s) "") ->
        Ok (decode_addon_phase (String.lowercase_ascii (String.trim s)))
    | `Null | `String _ -> Ok Addon_attached
    | bad -> field_type_error "phase" "an object {kind} or string" bad
  in
  let* auth_opt = optional_object_field json "execution_authority" in
  let* execution_kind =
    match auth_opt with
    | None -> Ok None
    | Some auth -> optional_nonblank_string auth "kind"
  in
  let resolved_image =
    match member "resolved_image" json with
    | `String s when String.trim s <> "" -> Some (String.trim s)
    | `Assoc _ as obj -> (
        match optional_nonblank_string obj "digest" with
        | Ok (Some d) -> Some d
        | Ok None | Error _ -> (
            match optional_nonblank_string obj "runtime" with
            | Ok (Some r) -> Some r
            | Ok None | Error _ -> None))
    | _ -> None
  in
  let* obs_seq_opt = optional_int_field json "observation_seq" in
  let* rows_cnt_opt = optional_int_field json "rows_count" in
  let* obs_pend_opt = optional_bool_field json "observation_pending" in
  let* vis_opt = optional_object_field json "visibility" in
  let* visibility_kind, visibility_keeper =
    match vis_opt with
    | None -> Ok (None, None)
    | Some vis ->
        let* vk = optional_nonblank_string vis "kind" in
        let* kp = optional_nonblank_string vis "keeper" in
        Ok (vk, kp)
  in
  let* host_opt = optional_object_field json "host_requests" in
  let* host_cycles, host_waiting_count, host_issue_kind =
    match host_opt with
    | None -> Ok (None, 0, None)
    | Some hr ->
        let* cyc = optional_int_field hr "cycles" in
        let wait_n =
          match optional_list_field hr "waiting" with
          | Ok xs -> List.length xs
          | Error _ -> 0
        in
        let* issue_k =
          match optional_object_field hr "issue" with
          | Ok (Some iss) -> optional_nonblank_string iss "kind"
          | Ok None -> Ok None
          | Error _ -> Ok None
        in
        Ok (cyc, wait_n, issue_k)
  in
  let action_names =
    match member "action_schema" json with
    | `Null -> []
    | schema_json -> extract_action_names_from_schema schema_json
  in
  let* cfg_opt = optional_object_field json "configuration" in
  let* config_declaration_id =
    match cfg_opt with
    | None -> Ok None
    | Some cfg -> optional_nonblank_string cfg "id"
  in
  Ok
    {
      runtime_presence;
      instance_id;
      addon_id;
      title;
      revision = Option.value ~default:"" rev_opt;
      phase;
      execution_kind;
      resolved_image;
      observation_seq = Option.value ~default:0 obs_seq_opt;
      rows_count = Option.value ~default:0 rows_cnt_opt;
      observation_pending = Option.value ~default:false obs_pend_opt;
      visibility_kind;
      visibility_keeper;
      host_cycles;
      host_waiting_count;
      host_issue_kind;
      action_names;
      config_declaration_id;
    }

let decode_lane_addons_issue json =
  let* sp = optional_nonblank_string json "source_path" in
  let* id = optional_nonblank_string json "id" in
  let* message = required_nonblank_string json "message" in
  Ok { source_path = Option.value ~default:"" sp; id; message }

let decode_lane_addons json =
  let* _, body = unwrap_v2_or_raw json in
  let* cfg_opt = optional_object_field body "configuration" in
  let* configuration_complete, declarations, issues =
    match cfg_opt with
    | None -> Ok (true, [], [])
    | Some cfg ->
        let* comp_opt = optional_bool_field cfg "complete" in
        let* decls_raw = optional_list_field cfg "declarations" in
        let* decls =
          decode_list "declarations" decode_addon_declaration decls_raw
        in
        let* iss_raw = optional_list_field cfg "issues" in
        let* iss = decode_list "issues" decode_lane_addons_issue iss_raw in
        Ok (Option.value ~default:true comp_opt, decls, iss)
  in
  let* inst_raw = optional_list_field body "instances" in
  let* instances = decode_list "instances" decode_addon_instance inst_raw in
  Ok { configuration_complete; declarations; instances; issues }

type lane_addon_ask_row = {
  declaration_id : string;
  title : string;
  ask_id : string;
  asked_at : float;
  context : string option;
  questions : Wire_work.ask_question list;
  resolution : Wire_work.ask_resolution;
}

let decode_lane_addon_ask_row json =
  let* declaration_id = required_nonblank_string json "declaration_id" in
  let* title = required_string_field json "title" in
  let* ask_id = required_nonblank_string json "ask_id" in
  let* asked_at = required_finite_float json "asked_at" in
  let* context = optional_nonblank_string json "context" in
  let* q_items = required_list_field json "questions" in
  let* questions =
    decode_list "questions" Wire_work.decode_ask_question q_items
  in
  let* res_json = required_object_field json "resolution" in
  let* resolution = Wire_work.decode_ask_resolution res_json in
  Ok { declaration_id; title; ask_id; asked_at; context; questions; resolution }

let decode_lane_addon_asks json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "asks" in
  decode_list "asks" decode_lane_addon_ask_row items

let encode_lane_addon_attach ~manifest_path ~run_id ~binding =
  `Assoc
    [
      ("manifest_path", `String (String.trim manifest_path));
      ("run_id", `String (String.trim run_id));
      ("binding", binding);
    ]

let encode_lane_addon_detach ~instance_id =
  `Assoc [ ("instance_id", `String (String.trim instance_id)) ]

let encode_lane_addon_action ~instance_id ~expected_incarnation ~request_id
    ~action =
  `Assoc
    [
      ("instance_id", `String (String.trim instance_id));
      ("expected_incarnation", `String (String.trim expected_incarnation));
      ("request_id", `String (String.trim request_id));
      ("action", action);
    ]

let encode_lane_addon_ask_answer ~declaration_id ~ask_id ?session_id ~answers ()
    =
  let session_field =
    match session_id with
    | Some sid when not (String.equal (String.trim sid) "") ->
        [ ("session_id", `String (String.trim sid)) ]
    | Some _ | None -> []
  in
  `Assoc
    ([
       ("declaration_id", `String (String.trim declaration_id));
       ("ask_id", `String (String.trim ask_id));
       ( "answers"
       , `List
           (List.map
              (fun (question_id, response) ->
                `Assoc
                  [
                    ("question_id", `String question_id);
                    ("response", Wire_work.encode_ask_response response);
                  ])
              answers) );
     ]
    @ session_field)

type mcp_client_row = {
  name : string;
  agent_type : string;
  keeper_name : string option;
  keeper_id : string option;
  status : string;
  current_task : string option;
  session_bound_at_unix : float option;
  last_seen_unix : float option;
  capabilities : string list;
}

let decode_mcp_client_row json =
  let* name = required_nonblank_string json "name" in
  let* agent_type = required_nonblank_string json "agent_type" in
  let* keeper_name = optional_nonblank_string json "keeper_name" in
  let* keeper_id = optional_nonblank_string json "keeper_id" in
  let* status = required_nonblank_string json "status" in
  let* current_task = optional_nonblank_string json "current_task" in
  let* session_bound_at_unix =
    decode_optional_timestamp_unix json "session_bound_at"
  in
  let* last_seen_unix = decode_optional_timestamp_unix json "last_seen" in
  let* capabilities = required_string_list json "capabilities" in
  Ok
    {
      name;
      agent_type;
      keeper_name;
      keeper_id;
      status;
      current_task;
      session_bound_at_unix;
      last_seen_unix;
      capabilities;
    }

let decode_mcp_clients json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "clients" in
  decode_list "clients" decode_mcp_client_row items

type runtime_config_raw_meta = {
  source_revision : string;
  assignments : (string * string) list;
}

let strip_toml_comment line =
  let len = String.length line in
  let rec scan i in_dq in_sq escaped =
    if i >= len then line
    else
      let c = line.[i] in
      if escaped then scan (i + 1) in_dq in_sq false
      else if in_dq then
        if Char.equal c '\\' then scan (i + 1) true false true
        else if Char.equal c '"' then scan (i + 1) false false false
        else scan (i + 1) true false false
      else if in_sq then
        if Char.equal c '\'' then scan (i + 1) false false false
        else scan (i + 1) false true false
      else if Char.equal c '"' then scan (i + 1) true false false
      else if Char.equal c '\'' then scan (i + 1) false true false
      else if Char.equal c '#' then String.sub line 0 i
      else scan (i + 1) false false false
  in
  scan 0 false false false

let unquote_toml_string raw =
  let s = String.trim raw in
  let len = String.length s in
  if len >= 2 && Char.equal s.[0] '"' && Char.equal s.[len - 1] '"' then
    Some (String.sub s 1 (len - 2))
  else if len >= 2 && Char.equal s.[0] '\'' && Char.equal s.[len - 1] '\'' then
    Some (String.sub s 1 (len - 2))
  else if len > 0 then Some s
  else None

let parse_runtime_assignments_from_toml source_text =
  let lines = String.split_on_char '\n' source_text in
  let in_assignments = ref false in
  let acc = ref [] in
  List.iter
    (fun raw_line ->
      let line = String.trim (strip_toml_comment raw_line) in
      if String.equal line "" then ()
      else if Char.equal line.[0] '[' then
        in_assignments := String.equal line "[runtime.assignments]"
      else if !in_assignments then
        match String.index_opt line '=' with
        | None -> ()
        | Some eq_idx -> (
            let raw_k = String.sub line 0 eq_idx in
            let raw_v =
              String.sub line (eq_idx + 1) (String.length line - eq_idx - 1)
            in
            match unquote_toml_string raw_k, unquote_toml_string raw_v with
            | Some k, Some v
              when (not (String.equal (String.trim k) ""))
                   && not (String.equal (String.trim v) "") ->
                acc := (String.trim k, String.trim v) :: !acc
            | _ -> ()))
    lines;
  List.rev !acc

let decode_runtime_config_raw_meta json =
  let* _, body = unwrap_v2_or_raw json in
  let* source_revision = required_nonblank_string body "source_revision" in
  let from_toml =
    match optional_string_field body "source_text" with
    | Ok (Some text) -> parse_runtime_assignments_from_toml text
    | Ok None | Error _ -> []
  in
  let assignments =
    if from_toml <> [] then from_toml
    else
      match optional_object_field body "model_bindings" with
      | Ok (Some mb) -> (
          match optional_list_field mb "assignments" with
          | Ok rows ->
              List.filter_map
                (fun row ->
                  match
                    optional_nonblank_string row "keeper_name",
                    optional_nonblank_string row "runtime_id"
                  with
                  | Ok (Some k), Ok (Some r) -> Some (k, r)
                  | (Ok (Some _ | None) | Error _), (Ok None | Error _)
                  | (Ok None | Error _), Ok (Some _) ->
                      None)
                rows
          | Error _ -> [])
      | Ok None | Error _ -> []
  in
  Ok { source_revision; assignments }

let encode_runtime_assignment ~keeper_name ~runtime_id ~source_revision
    ~previous_runtime_id () =
  let expected_rev =
    match source_revision with
    | None -> `Assoc [ ("state", `String "runtime_config_missing") ]
    | Some rev ->
        let assignment =
          match previous_runtime_id with
          | None -> `Assoc [ ("state", `String "missing") ]
          | Some prev_id ->
              `Assoc
                [ ("state", `String "assigned"); ("runtime_id", `String prev_id) ]
        in
        `Assoc
          [
            ("state", `String "runtime_config_present");
            ("source_revision", `String rev);
            ("assignment", assignment);
          ]
  in
  `Assoc
    [
      ("keeper_name", `String keeper_name);
      ( "runtime_id"
      , match runtime_id with Some id -> `String id | None -> `Null );
      ("expected_assignment_revision", expected_rev);
    ]

let encode_runtime_default_route ~runtime_id =
  `Assoc [ ("lane", `String "default"); ("runtime_id", `String runtime_id) ]

type lane_kind =
  | Lane_failover
  | Lane_exact_output

let equal_lane_kind a b =
  match a, b with
  | Lane_failover, Lane_failover | Lane_exact_output, Lane_exact_output -> true
  | Lane_failover, Lane_exact_output | Lane_exact_output, Lane_failover -> false

let lane_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "failover" -> Some Lane_failover
  | "exact_output" -> Some Lane_exact_output
  | _ -> None

let lane_kind_to_string = function
  | Lane_failover -> "failover"
  | Lane_exact_output -> "exact_output"

let known_exact_lane_ids =
  [
    "librarian_exact";
    "hitl_auto_judge";
    "board_attention_exact";
    "verifier_exact";
    "candle_appraiser";
    "librarian_memory";
    "workspace_memory_curator";
  ]

let is_known_exact_lane_id id =
  List.exists (String.equal (String.trim id)) known_exact_lane_ids

let is_lowercase_sha256_hex s =
  String.length s = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       s

let parse_candidate_runtime_ids raw =
  let len = String.length raw in
  let is_sep = function ',' | ';' | '\n' | '\r' -> true | _ -> false in
  let rec loop acc start i =
    if i >= len then
      let piece = String.trim (String.sub raw start (len - start)) in
      List.rev (if String.equal piece "" then acc else piece :: acc)
    else if is_sep raw.[i] then
      let piece = String.trim (String.sub raw start (i - start)) in
      let acc = if String.equal piece "" then acc else piece :: acc in
      loop acc (i + 1) (i + 1)
    else loop acc start (i + 1)
  in
  loop [] 0 0

let exact_route_name lane_id =
  let trimmed = String.trim lane_id in
  if String.starts_with ~prefix:"exact/" trimmed then trimmed
  else "exact/" ^ trimmed

let encode_runtime_lane_create ~lane_id ~kind ~runtime_ids =
  let ids_json = `List (List.map (fun s -> `String s) runtime_ids) in
  match kind with
  | Lane_failover ->
      `Assoc
        [
          ("lane", `String (String.trim lane_id));
          ("action", `String "create");
          ("runtime_ids", ids_json);
        ]
  | Lane_exact_output ->
      `Assoc
        [
          ("lane", `String (exact_route_name lane_id));
          ("action", `String "set");
          ("runtime_ids", ids_json);
        ]

let encode_runtime_lane_update ~lane_id ~kind ~runtime_ids
    ?expected_source_revision () =
  let ids_json = `List (List.map (fun s -> `String s) runtime_ids) in
  match kind with
  | Lane_failover ->
      let rev_field =
        match expected_source_revision with
        | Some rev when is_lowercase_sha256_hex rev ->
            [ ("expected_source_revision", `String rev) ]
        | Some _ | None -> []
      in
      `Assoc
        ([
           ("lane", `String (String.trim lane_id));
           ("action", `String "set");
           ("runtime_ids", ids_json);
         ]
        @ rev_field)
  | Lane_exact_output ->
      `Assoc
        [
          ("lane", `String (exact_route_name lane_id));
          ("action", `String "set");
          ("runtime_ids", ids_json);
        ]

let encode_runtime_lane_delete ~lane_id ?expected_source_revision () =
  let rev_field =
    match expected_source_revision with
    | Some rev when is_lowercase_sha256_hex rev ->
        [ ("expected_source_revision", `String rev) ]
    | Some _ | None -> []
  in
  `Assoc
    ([ ("lane", `String (String.trim lane_id)); ("action", `String "remove") ]
    @ rev_field)

type setup_integration = {
  id : string;
  display_name : string;
  protocol : string option;
  origin : string;
  setup_support : string;
  enabled : bool;
  credential_kind : string option;
  configured_runtime_ids : string list;
}

type setup_inventory = {
  default_runtime_id : string option;
  integrations : setup_integration list;
}

let decode_setup_integration json =
  let* id = required_nonblank_string json "id" in
  let* display_name = required_nonblank_string json "display_name" in
  let* protocol = optional_nonblank_string json "protocol" in
  let* origin = required_nonblank_string json "origin" in
  let* setup_support = required_nonblank_string json "setup_support" in
  let* enabled =
    match optional_bool_field json "enabled" with
    | Ok (Some b) -> Ok b
    | Ok None -> Ok true
    | Error _ as err -> err
  in
  let* credential_kind = optional_nonblank_string json "credential_kind" in
  let* configured_runtime_ids =
    optional_string_list json "configured_runtime_ids"
  in
  Ok
    {
      id;
      display_name;
      protocol;
      origin;
      setup_support;
      enabled;
      credential_kind;
      configured_runtime_ids;
    }

let decode_setup_inventory json =
  let* _, body = unwrap_v2_or_raw json in
  let* default_runtime_id = optional_nonblank_string body "default_runtime_id" in
  let* items = optional_list_field body "integrations" in
  let* integrations = decode_list "integrations" decode_setup_integration items in
  Ok { default_runtime_id; integrations }

type setup_login_receipt = {
  login_id : string;
  integration_id : string;
  status : string;
  account : string option;
  account_ref : string option;
  authentication : string option;
}

let decode_setup_login_receipt json =
  let* _, body = unwrap_v2_or_raw json in
  let* login_id = required_nonblank_string body "login_id" in
  let* integration_id = required_nonblank_string body "integration_id" in
  let* account = optional_nonblank_string body "account" in
  let* account_ref = optional_nonblank_string body "account_ref" in
  let* authentication = optional_nonblank_string body "authentication" in
  let* status =
    match optional_nonblank_string body "status" with
    | Ok (Some s) -> Ok s
    | Ok None -> (
        match optional_nonblank_string body "error" with
        | Ok (Some _) -> Ok "failed"
        | Ok None | Error _ ->
            if Option.is_some authentication then Ok "complete" else Ok "running")
    | Error _ as err -> err
  in
  Ok { login_id; integration_id; status; account; account_ref; authentication }

let encode_setup_credential ~provider_id ~secret ~source_revision =
  `Assoc
    [
      ("provider_id", `String provider_id);
      ("secret", `String secret);
      ("source_revision", `String source_revision);
    ]

let encode_setup_account_login_start ~integration_id ?account_ref () =
  `Assoc
    (("integration_id", `String integration_id)
    ::
    (match account_ref with
    | Some r when not (String.equal (String.trim r) "") ->
        [ ("account_ref", `String (String.trim r)) ]
    | Some _ | None -> []))

type setup_login_key =
  | Login_key_enter
  | Login_key_up
  | Login_key_down
  | Login_key_tab
  | Login_key_eof

type setup_login_input =
  | Setup_login_text of string
  | Setup_login_key of setup_login_key

let setup_login_key_to_string = function
  | Login_key_enter -> "enter"
  | Login_key_up -> "up"
  | Login_key_down -> "down"
  | Login_key_tab -> "tab"
  | Login_key_eof -> "eof"

let encode_setup_login_input = function
  | Setup_login_text text ->
      `Assoc [ ("kind", `String "text"); ("text", `String text) ]
  | Setup_login_key key ->
      `Assoc
        [
          ("kind", `String "key");
          ("key", `String (setup_login_key_to_string key));
        ]

let strip_ansi_csi s =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then Buffer.contents buf
    else if s.[i] = '\027' && i + 1 < len && s.[i + 1] = '[' then
      let rec skip j =
        if j >= len then len
        else
          let c = s.[j] in
          if c >= '@' && c <= '~' then j + 1 else skip (j + 1)
      in
      loop (skip (i + 2))
    else (
      Buffer.add_char buf s.[i];
      loop (i + 1))
  in
  loop 0

let extract_https_url raw =
  let clean = strip_ansi_csi raw in
  let len = String.length clean in
  let prefix = "https://" in
  let plen = String.length prefix in
  let rec find_start i =
    if i + plen > len then None
    else if String.equal (String.sub clean i plen) prefix then Some i
    else find_start (i + 1)
  in
  let is_url_stop = function
    | ' ' | '\t' | '\n' | '\r' | '"' | '\'' | '<' | '>' | '\027' -> true
    | c when Char.code c < 32 || Char.code c = 127 -> true
    | _ -> false
  in
  let is_trailing_punct = function
    | '.' | ',' | ';' | ')' | ']' | '}' | ':' -> true
    | _ -> false
  in
  match find_start 0 with
  | None -> None
  | Some start ->
      let rec find_end j =
        if j >= len || is_url_stop clean.[j] then j else find_end (j + 1)
      in
      let rec trim_end j =
        if j > start + plen && is_trailing_punct clean.[j - 1] then
          trim_end (j - 1)
        else j
      in
      let stop = trim_end (find_end (start + plen)) in
      if stop > start + plen then Some (String.sub clean start (stop - start))
      else None

let contains_ascii_ci ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hlen = String.length h in
  let nlen = String.length n in
  if nlen = 0 then true
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.equal (String.sub h i nlen) n then true
      else loop (i + 1)
    in
    loop 0

let has_device_code_context s =
  List.exists
    (fun cue -> contains_ascii_ci ~needle:cue s)
    [ "one-time"; "device"; "verify"; "verification"; "enter"; "code"; "oauth" ]

let extract_device_code raw =
  let clean = strip_ansi_csi raw in
  if not (has_device_code_context clean) then None
  else
    let len = String.length clean in
    let is_upper_alpha = function 'A' .. 'Z' -> true | _ -> false in
    let is_upper_alnum = function 'A' .. 'Z' | '0' .. '9' -> true | _ -> false in
    let is_boundary i =
      i < 0 || i >= len
      ||
      match clean.[i] with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '/' | ':' -> false
      | _ -> true
    in
    let has_letter s =
      let slen = String.length s in
      let rec check k =
        if k >= slen then false
        else if is_upper_alpha s.[k] then true
        else check (k + 1)
      in
      check 0
    in
    let rec scan i =
      if i >= len then None
      else if is_upper_alnum clean.[i] && is_boundary (i - 1) then
        let rec take_alnum j =
          if j < len && is_upper_alnum clean.[j] then take_alnum (j + 1) else j
        in
        let j1 = take_alnum i in
        let n1 = j1 - i in
        if n1 >= 4 && n1 <= 6 && j1 < len && clean.[j1] = '-' then
          let j2 = take_alnum (j1 + 1) in
          let n2 = j2 - (j1 + 1) in
          if n2 >= 4 && n2 <= 6 && is_boundary j2 then
            let candidate = String.sub clean i (j2 - i) in
            if has_letter candidate then Some candidate else scan (j2 + 1)
          else scan (j1 + 1)
        else scan (j1 + 1)
      else scan (i + 1)
    in
    scan 0

(* --- Wave 3: Fusion Detail, Config Presets, Addon Package Catalog & Connector Names --- *)

let fusion_run_detail_path ~run_id =
  "/api/v1/dashboard/fusion-runs/" ^ percent_encode run_id

let fusion_config_path = "/api/v1/runtime/config/fusion"

let fusion_board_post_path ~post_id =
  "/api/v1/board/" ^ percent_encode post_id

let lane_addon_package_catalog_path ?directory () =
  match directory with
  | Some d when not (String.equal (String.trim d) "") ->
      "/api/v1/lane-addons/package-catalog?directory="
      ^ percent_encode (String.trim d)
  | Some _ | None -> "/api/v1/lane-addons/package-catalog"

let lane_addon_package_preview_path ~manifest_path =
  "/api/v1/lane-addons/package-preview?manifest_path="
  ^ percent_encode manifest_path

let connector_names_path ~connector ?(scope = "channel") ?limit () =
  let params =
    [
      "name=" ^ percent_encode connector;
      "scope=" ^ percent_encode scope;
    ]
    @
    match limit with
    | Some n -> [ Printf.sprintf "limit=%d" (max 1 n) ]
    | None -> []
  in
  "/api/v1/gate/connector/names?" ^ String.concat "&" params

type fusion_replay_status =
  | Replay_not_replayed
  | Replay_absent
  | Replay_complete of {
      lines_read : int;
      malformed_lines : int;
      dropped_running : int;
    }
  | Replay_incomplete of {
      reason : string;
      lines_read : int;
      malformed_lines : int;
    }

type fusion_historical_evidence = {
  run_id : string;
  post_id : string;
  title : string;
  created_at_unix : float;
}

type fusion_runs_snapshot = {
  generated_at : string;
  replay : fusion_replay_status option;
  historical_evidence : fusion_historical_evidence list;
  runs : fusion_run list;
}

type fusion_panel_entry = {
  model : string;
  status : [ `Answered | `Failed ];
  answer : string option;
  input_tokens : int option;
  output_tokens : int option;
  reason_code : string option;
  reason_detail : string option;
}

type fusion_judge_node = {
  role : string;
  identity : string;
  status : string;
  decision : string option;
  resolved_answer : string option;
  synthesis : string option;
  input_tokens : int;
  output_tokens : int;
  failure_code : string option;
  error : string option;
  elapsed_s : float option;
  timed_out : bool option;
}

type fusion_seat_attempt = {
  runtime : string;
  code : string;
  detail : string;
}

type fusion_seat_route = {
  phase : string;
  seat : string;
  judge_role : string option;
  route : string;
  answered_by : string option;
  failed_attempts : fusion_seat_attempt list;
}

type fusion_tool_trace = {
  status : string;
  observed_actors : string list;
  dropped_events : int;
  gaps : string list;
  events_count : int;
  events_preview : string list;
}

type fusion_evidence_post = {
  post_id : string;
  title : string;
  author : string;
  body : string;
  question : string option;
  panel : fusion_panel_entry list;
  judge_status : string option;
  judge_decision : string option;
  judge_synthesis : string option;
  judge_resolved_answer : string option;
  judge_failure : string option;
  judges : fusion_judge_node list;
  seat_routes : fusion_seat_route list;
  tool_trace : fusion_tool_trace option;
}

type fusion_evidence_status =
  | Evidence_recorded of fusion_evidence_post
  | Evidence_pending
  | Evidence_absent

type fusion_run_detail = {
  run : fusion_run;
  evidence : fusion_evidence_status;
}

type fusion_preset_option = {
  name : string;
  panels : string list;
  judge : string option;
  judges : string list;
  min_answered : int option;
}

type fusion_config_options = {
  enabled : bool;
  default_preset : string;
  staged_judge_group_size : int;
  presets : fusion_preset_option list;
}

let int_or_zero json key =
  match optional_int_field json key with Ok (Some n) -> n | Ok None | Error _ -> 0

let decode_fusion_replay_opt body =
  match optional_object_field body "replay" with
  | Error _ as err -> err
  | Ok None -> Ok None
  | Ok (Some r) -> (
      let* status = required_nonblank_string r "status" in
      match status with
      | "not_replayed" -> Ok (Some Replay_not_replayed)
      | "absent" -> Ok (Some Replay_absent)
      | "complete" ->
          Ok
            (Some
               (Replay_complete
                  {
                    lines_read = int_or_zero r "lines_read";
                    malformed_lines = int_or_zero r "malformed_lines";
                    dropped_running = int_or_zero r "dropped_running";
                  }))
      | "incomplete" ->
          let reason =
            match optional_nonblank_string r "reason" with
            | Ok (Some s) -> s
            | Ok None | Error _ -> "incomplete replay"
          in
          Ok
            (Some
               (Replay_incomplete
                  {
                    reason;
                    lines_read = int_or_zero r "lines_read";
                    malformed_lines = int_or_zero r "malformed_lines";
                  }))
      | other -> Error (Printf.sprintf "unknown fusion replay status %S" other))

let decode_fusion_historical_evidence_row json =
  let* run_id = required_nonblank_string json "run_id" in
  let* post_id = required_nonblank_string json "post_id" in
  let* title =
    match optional_string_field json "title" with
    | Ok (Some s) -> Ok s
    | Ok None -> Ok run_id
    | Error _ as err -> err
  in
  let* created_at_unix =
    match optional_finite_float json "created_at" with
    | Ok (Some f) -> Ok f
    | Ok None -> Ok 0.0
    | Error _ as err -> err
  in
  Ok { run_id; post_id; title; created_at_unix }

let decode_fusion_runs_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let generated_at =
    match optional_string_field body "generated_at" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* replay = decode_fusion_replay_opt body in
  let* hist_items = optional_list_field body "historical_evidence" in
  let* historical_evidence =
    decode_list "historical_evidence" decode_fusion_historical_evidence_row
      hist_items
  in
  let* run_items = required_list_field body "runs" in
  let* runs = decode_list "runs" decode_fusion_run run_items in
  Ok { generated_at; replay; historical_evidence; runs }

let decode_fusion_panel_entry json =
  let* model = required_nonblank_string json "model" in
  let* status_str = required_nonblank_string json "status" in
  let* status =
    match status_str with
    | "answered" -> Ok `Answered
    | "failed" -> Ok `Failed
    | other -> Error (Printf.sprintf "unknown fusion panel status %S" other)
  in
  let* answer = optional_string_field json "answer" in
  let* input_tokens = optional_int_field json "input_tokens" in
  let* output_tokens = optional_int_field json "output_tokens" in
  let* reason_code = optional_nonblank_string json "reason_code" in
  let* reason_detail = optional_nonblank_string json "reason_detail" in
  Ok
    {
      model;
      status;
      answer;
      input_tokens;
      output_tokens;
      reason_code;
      reason_detail;
    }

let decode_fusion_judge_node json =
  let* role =
    match optional_nonblank_string json "role" with
    | Ok (Some r) -> Ok r
    | Ok None -> Ok "single"
    | Error _ as err -> err
  in
  let* identity =
    match optional_nonblank_string json "identity" with
    | Ok (Some id) -> Ok id
    | Ok None -> (
        match optional_nonblank_string json "model" with
        | Ok (Some m) -> Ok m
        | Ok None -> Ok "judge"
        | Error _ as err -> err)
    | Error _ as err -> err
  in
  let* status = required_nonblank_string json "status" in
  let* decision = optional_nonblank_string json "decision" in
  let* resolved_answer = optional_string_field json "resolved_answer" in
  let* synthesis = optional_string_field json "synthesis" in
  let input_tokens = int_or_zero json "input_tokens" in
  let output_tokens = int_or_zero json "output_tokens" in
  let* failure_code = optional_nonblank_string json "failure_code" in
  let* error = optional_nonblank_string json "error" in
  let* elapsed_s = optional_finite_float json "elapsed_s" in
  let* timed_out = optional_bool_field json "timed_out" in
  Ok
    {
      role;
      identity;
      status;
      decision;
      resolved_answer;
      synthesis;
      input_tokens;
      output_tokens;
      failure_code;
      error;
      elapsed_s;
      timed_out;
    }

let decode_fusion_seat_attempt json =
  let* runtime = required_nonblank_string json "runtime" in
  let* code =
    match optional_nonblank_string json "code" with
    | Ok (Some c) -> Ok c
    | Ok None -> Ok "failed"
    | Error _ as err -> err
  in
  let* detail =
    match optional_string_field json "detail" with
    | Ok (Some d) -> Ok d
    | Ok None -> Ok ""
    | Error _ as err -> err
  in
  Ok { runtime; code; detail }

let decode_fusion_seat_route json =
  let* phase = required_nonblank_string json "phase" in
  let* seat = required_nonblank_string json "seat" in
  let* judge_role = optional_nonblank_string json "judge_role" in
  let* route =
    match optional_nonblank_string json "route" with
    | Ok (Some r) -> Ok r
    | Ok None -> Ok ""
    | Error _ as err -> err
  in
  let* answered_by = optional_nonblank_string json "answered_by" in
  let* failed_items = optional_list_field json "failed_attempts" in
  let* failed_attempts =
    decode_list "failed_attempts" decode_fusion_seat_attempt failed_items
  in
  Ok { phase; seat; judge_role; route; answered_by; failed_attempts }

let summarize_trace_event = function
  | `Assoc _ as ev ->
      let actor =
        match optional_nonblank_string ev "actor" with
        | Ok (Some a) -> a
        | Ok None | Error _ -> "?"
      in
      let tool =
        match optional_nonblank_string ev "tool_name" with
        | Ok (Some t) -> t
        | Ok None | Error _ -> (
            match optional_nonblank_string ev "tool" with
            | Ok (Some t) -> t
            | Ok None | Error _ -> (
                match optional_nonblank_string ev "kind" with
                | Ok (Some k) -> k
                | Ok None | Error _ -> "event"))
      in
      let status_tag =
        match optional_nonblank_string ev "status" with
        | Ok (Some "succeeded") -> "ok"
        | Ok (Some "failed") -> (
            match optional_nonblank_string ev "error_class" with
            | Ok (Some cls) -> "err:" ^ cls
            | Ok None | Error _ -> "err")
        | Ok (Some s) -> s
        | Ok None | Error _ -> (
            match optional_nonblank_string ev "event" with
            | Ok (Some "called") -> "call"
            | Ok (Some "completed") -> (
                match optional_bool_field ev "ok" with
                | Ok (Some true) -> "ok"
                | Ok (Some false) -> "err"
                | Ok None | Error _ -> "done")
            | Ok (Some e) -> e
            | Ok None | Error _ -> (
                match optional_bool_field ev "ok" with
                | Ok (Some true) -> "ok"
                | Ok (Some false) -> "err"
                | Ok None | Error _ -> ""))
      in
      if String.equal status_tag "" then Printf.sprintf "%s -> %s" actor tool
      else Printf.sprintf "%s -> %s [%s]" actor tool status_tag
  | other -> Yojson.Safe.to_string other

let decode_trace_actor_item = function
  | `String s -> Ok s
  | `Assoc _ as obj ->
      let phase =
        match optional_nonblank_string obj "phase" with
        | Ok (Some p) -> p
        | Ok None | Error _ -> ""
      in
      let role =
        match optional_nonblank_string obj "judge_role" with
        | Ok (Some r) -> "/" ^ r
        | Ok None | Error _ -> ""
      in
      let actor =
        match optional_nonblank_string obj "actor" with
        | Ok (Some a) -> a
        | Ok None | Error _ -> "?"
      in
      if String.equal phase "" then Ok actor
      else Ok (Printf.sprintf "%s%s:%s" phase role actor)
  | bad -> field_type_error "observed_actors[]" "string or object" bad

let decode_trace_gap_item = function
  | `String s -> Ok s
  | `Assoc _ as obj ->
      let* actor_s = decode_trace_actor_item obj in
      let reason =
        match optional_nonblank_string obj "reason" with
        | Ok (Some r) -> r
        | Ok None | Error _ -> "gap"
      in
      Ok (Printf.sprintf "%s (%s)" actor_s reason)
  | bad -> field_type_error "gaps[]" "string or object" bad

let decode_fusion_tool_trace json =
  let* status =
    match optional_nonblank_string json "status" with
    | Ok (Some s) -> Ok s
    | Ok None -> Ok "complete"
    | Error _ as err -> err
  in
  let* actor_items = optional_list_field json "observed_actors" in
  let* observed_actors =
    decode_list "observed_actors" decode_trace_actor_item actor_items
  in
  let dropped_events = int_or_zero json "dropped_events" in
  let* gap_items = optional_list_field json "gaps" in
  let* gaps = decode_list "gaps" decode_trace_gap_item gap_items in
  let* events = optional_list_field json "events" in
  let events_count = List.length events in
  let events_preview =
    events
    |> List.filteri (fun i _ -> i < 12)
    |> List.map summarize_trace_event
  in
  Ok { status; observed_actors; dropped_events; gaps; events_count; events_preview }

let decode_fusion_evidence_post post =
  let* post_id =
    match optional_nonblank_string post "id" with
    | Ok (Some id) -> Ok id
    | Ok None -> Ok ""
    | Error _ as err -> err
  in
  let* title =
    match optional_string_field post "title" with
    | Ok (Some s) -> Ok s
    | Ok None -> Ok ""
    | Error _ as err -> err
  in
  let* author =
    match optional_string_field post "author" with
    | Ok (Some s) -> Ok s
    | Ok None -> Ok ""
    | Error _ as err -> err
  in
  let* body =
    match optional_string_field post "body" with
    | Ok (Some s) -> Ok s
    | Ok None -> (
        match optional_string_field post "content" with
        | Ok (Some s) -> Ok s
        | Ok None -> Ok ""
        | Error _ as err -> err)
    | Error _ as err -> err
  in
  let* meta_opt = optional_object_field post "meta" in
  let meta = Option.value ~default:(`Assoc []) meta_opt in
  let* question = optional_string_field meta "question" in
  let* panel_items = optional_list_field meta "panel" in
  let* panel = decode_list "panel" decode_fusion_panel_entry panel_items in
  let* judge_opt = optional_object_field meta "judge" in
  let judge_status, judge_decision, judge_synthesis, judge_resolved_answer, judge_failure =
    match judge_opt with
    | None -> (None, None, None, None, None)
    | Some j ->
        let get_str k =
          match optional_string_field j k with Ok v -> v | Error _ -> None
        in
        let failure =
          match get_str "error", get_str "failure_code" with
          | Some e, Some c -> Some (c ^ ": " ^ e)
          | Some e, None -> Some e
          | None, Some c -> Some c
          | None, None -> None
        in
        ( get_str "status",
          get_str "decision",
          get_str "synthesis",
          get_str "resolved_answer",
          failure )
  in
  let* judges_items = optional_list_field meta "judges" in
  let* judges = decode_list "judges" decode_fusion_judge_node judges_items in
  let* seat_items =
    match optional_list_field meta "seat_routes" with
    | Ok (_ :: _ as xs) -> Ok xs
    | Ok [] -> optional_list_field post "seat_routes"
    | Error _ as err -> err
  in
  let* seat_routes = decode_list "seat_routes" decode_fusion_seat_route seat_items in
  let* tool_trace =
    match optional_object_field meta "tool_trace" with
    | Ok None -> Ok None
    | Ok (Some tt) ->
        let* decoded = decode_fusion_tool_trace tt in
        Ok (Some decoded)
    | Error _ as err -> err
  in
  Ok
    {
      post_id;
      title;
      author;
      body;
      question;
      panel;
      judge_status;
      judge_decision;
      judge_synthesis;
      judge_resolved_answer;
      judge_failure;
      judges;
      seat_routes;
      tool_trace;
    }

let decode_fusion_run_detail json =
  let* _, body = unwrap_v2_or_raw json in
  let* run_obj = required_object_field body "run" in
  let* run = decode_fusion_run run_obj in
  let* ev_obj = required_object_field body "evidence" in
  let* status = required_nonblank_string ev_obj "status" in
  let* evidence =
    match status with
    | "recorded" -> (
        match optional_object_field ev_obj "post" with
        | Ok (Some post_obj) ->
            let* post = decode_fusion_evidence_post post_obj in
            Ok (Evidence_recorded post)
        | Ok None -> Ok Evidence_absent
        | Error _ as err -> err)
    | "pending" -> Ok Evidence_pending
    | "absent" -> Ok Evidence_absent
    | other -> Error (Printf.sprintf "unknown fusion evidence status %S" other)
  in
  Ok { run; evidence }

let decode_fusion_board_evidence json =
  let* _, body = unwrap_v2_or_raw json in
  let post_obj =
    match optional_object_field body "post" with
    | Ok (Some p) -> p
    | Ok None | Error _ -> body
  in
  decode_fusion_evidence_post post_obj

let decode_fusion_panel_group_label = function
  | `String s -> Ok s
  | `Assoc _ as obj ->
      let label =
        match optional_nonblank_string obj "label" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> ""
      in
      let* models = optional_string_list obj "models" in
      let models_s = String.concat "," models in
      if not (String.equal label "") && not (String.equal models_s "") then
        Ok (label ^ ":" ^ models_s)
      else if not (String.equal models_s "") then Ok models_s
      else if not (String.equal label "") then Ok label
      else Ok "panel"
  | bad -> field_type_error "panels[]" "string or panel_group object" bad

let decode_fusion_judge_spec_label = function
  | `String s -> Ok s
  | `Assoc _ as obj ->
      let label =
        match optional_nonblank_string obj "label" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> ""
      in
      let model =
        match optional_nonblank_string obj "model" with
        | Ok (Some m) -> m
        | Ok None | Error _ -> ""
      in
      if not (String.equal label "") && not (String.equal model "") then
        Ok (label ^ ":" ^ model)
      else if not (String.equal model "") then Ok model
      else if not (String.equal label "") then Ok label
      else Ok "judge"
  | bad -> field_type_error "judges[]" "string or judge_spec object" bad

let decode_fusion_preset_option json =
  let* name = required_nonblank_string json "name" in
  let* panel_items = optional_list_field json "panels" in
  let* panels = decode_list "panels" decode_fusion_panel_group_label panel_items in
  let* judge = optional_nonblank_string json "judge" in
  let* judge_items = optional_list_field json "judges" in
  let* judges = decode_list "judges" decode_fusion_judge_spec_label judge_items in
  let* min_answered = optional_int_field json "min_answered" in
  Ok { name; panels; judge; judges; min_answered }

let decode_fusion_config_options json =
  let* _, body = unwrap_v2_or_raw json in
  let cfg =
    match optional_object_field body "config" with
    | Ok (Some c) -> c
    | Ok None | Error _ -> body
  in
  let enabled =
    match optional_bool_field cfg "enabled" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> true
  in
  let default_preset =
    match optional_nonblank_string cfg "default_preset" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let staged_judge_group_size = int_or_zero cfg "staged_judge_group_size" in
  let* preset_items = optional_list_field cfg "presets" in
  let* presets =
    decode_list "presets" decode_fusion_preset_option preset_items
  in
  Ok { enabled; default_preset; staged_judge_group_size; presets }

type addon_catalog_entry =
  | Catalog_folder of { path : string }
  | Catalog_issue of { path : string; message : string }
  | Catalog_package of {
      manifest_path : string;
      title : string;
      revision : string;
      description : string option;
      ui_category : string option;
    }

type addon_package_catalog = {
  directory : string;
  parent : string option;
  entries : addon_catalog_entry list;
}

type addon_package_preview = {
  manifest_path : string;
  id : string;
  revision : string;
  title : string;
  ui_category : string option;
  execution_kind : string;
  image_name : string option;
  image_state : string option;
  exported_tools : string list;
  contributions : string list;
  command : string list;
  directory : string option;
}

let decode_addon_catalog_entry json =
  let* kind = required_nonblank_string json "kind" in
  match kind with
  | "folder" ->
      let* path = required_nonblank_string json "path" in
      Ok (Catalog_folder { path })
  | "issue" ->
      let* path = required_nonblank_string json "path" in
      let* message = required_string_field json "message" in
      Ok (Catalog_issue { path; message })
  | "package" ->
      let* manifest_path = required_nonblank_string json "manifest_path" in
      let* title = required_nonblank_string json "title" in
      let* revision =
        match optional_nonblank_string json "revision" with
        | Ok (Some r) -> Ok r
        | Ok None -> Ok "0"
        | Error _ as err -> err
      in
      let* description = optional_nonblank_string json "description" in
      let* ui_category = optional_nonblank_string json "ui_category" in
      Ok
        (Catalog_package
           { manifest_path; title; revision; description; ui_category })
  | other -> Error (Printf.sprintf "unknown package catalog entry kind %S" other)

let decode_addon_package_catalog json =
  let* _, body = unwrap_v2_or_raw json in
  let* directory =
    match optional_string_field body "directory" with
    | Ok (Some d) -> Ok d
    | Ok None -> Ok ""
    | Error _ as err -> err
  in
  let* parent = optional_nonblank_string body "parent" in
  let* items = required_list_field body "entries" in
  let* entries = decode_list "entries" decode_addon_catalog_entry items in
  Ok { directory; parent; entries }

let decode_addon_package_preview json =
  let* _, body = unwrap_v2_or_raw json in
  let* manifest_path = required_nonblank_string body "manifest_path" in
  let* pkg = required_object_field body "package" in
  let* id = required_nonblank_string pkg "id" in
  let* revision =
    match optional_nonblank_string pkg "revision" with
    | Ok (Some r) -> Ok r
    | Ok None -> Ok "0"
    | Error _ as err -> err
  in
  let* title = required_nonblank_string pkg "title" in
  let* ui_category = optional_nonblank_string pkg "ui_category" in
  let* command = optional_string_list pkg "command" in
  let* directory = optional_nonblank_string pkg "directory" in
  let* contrib_items = optional_list_field pkg "contributions" in
  let contributions =
    List.filter_map
      (function
        | `String s -> Some s
        | `Assoc _ as obj -> (
            match optional_nonblank_string obj "kind" with
            | Ok (Some k) -> Some k
            | Ok None | Error _ -> None)
        | _ -> None)
      contrib_items
  in
  let* tool_items = optional_list_field pkg "exported_tools" in
  let exported_tools =
    List.filter_map
      (function
        | `String s -> Some s
        | `Assoc _ as obj -> (
            match optional_nonblank_string obj "name" with
            | Ok (Some n) -> Some n
            | Ok None | Error _ -> None)
        | _ -> None)
      tool_items
  in
  let* exec_opt = optional_object_field body "execution" in
  let execution_kind, image_name, image_state =
    match exec_opt with
    | None -> ("host_process", None, None)
    | Some ex ->
        let kind =
          match optional_nonblank_string ex "kind" with
          | Ok (Some k) -> k
          | Ok None | Error _ -> "host_process"
        in
        let img_name =
          match optional_nonblank_string ex "image_name" with
          | Ok v -> v
          | Error _ -> None
        in
        let img_state =
          match optional_object_field ex "image" with
          | Ok (Some img) -> (
              match optional_nonblank_string img "state" with
              | Ok v -> v
              | Error _ -> None)
          | Ok None | Error _ -> None
        in
        (kind, img_name, img_state)
  in
  Ok
    {
      manifest_path;
      id;
      revision;
      title;
      ui_category;
      execution_kind;
      image_name;
      image_state;
      exported_tools;
      contributions;
      command;
      directory;
    }

type connector_name_mapping = {
  id : string;
  name : string;
}

type connector_names_page = {
  connector_id : string;
  kind : string;
  total : int;
  has_more : bool;
  mappings : connector_name_mapping list;
}

let decode_connector_name_mapping json =
  let* id = required_nonblank_string json "id" in
  let* name = required_nonblank_string json "name" in
  Ok { id; name }

let decode_connector_names_page json =
  let* _, body = unwrap_v2_or_raw json in
  let* connector_id = required_nonblank_string body "connector_id" in
  let* kind =
    match optional_nonblank_string body "kind" with
    | Ok (Some k) -> Ok k
    | Ok None -> Ok "channel"
    | Error _ as err -> err
  in
  let total = int_or_zero body "total" in
  let has_more =
    match optional_bool_field body "has_more" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let* items = optional_list_field body "mappings" in
  let* mappings = decode_list "mappings" decode_connector_name_mapping items in
  Ok { connector_id; kind; total; has_more; mappings }

(* ========================================================================= *)
(* Wave 4 Layer 2: Tool Quality, Keeper Waiting Inventory & Stateless MCP    *)
(* ========================================================================= *)

type tool_quality_tool_row = {
  name : string;
  calls : int;
  success_pct : float;
  avg_ms : float;
  output_truncated_count : int;
  avg_output_chars : float;
}

type tool_quality_rate_row = {
  name : string;
  calls : int;
  success_pct : float;
}

type tool_quality_failure_cat = {
  category : string;
  count : int;
}

type tool_quality_snapshot = {
  generated_at : string;
  sampling_mode : string;
  total : int;
  success : int;
  failure : int;
  deferred : int;
  unsettled : int;
  malformed : int;
  success_rate : float;
  by_tool : tool_quality_tool_row list;
  by_keeper : tool_quality_rate_row list;
  by_runtime : tool_quality_rate_row list;
  failure_categories : tool_quality_failure_cat list;
}

let decode_tool_quality_tool_row json =
  let* name = required_nonblank_string json "name" in
  let* calls = required_nonnegative_int_field json "calls" in
  let* success_pct = required_finite_float json "success_pct" in
  let* avg_ms = required_nonnegative_float json "avg_ms" in
  let output_truncated_count = int_or_zero json "output_truncated_count" in
  let avg_output_chars =
    match optional_finite_float json "avg_output_chars" with
    | Ok (Some v) -> v
    | Ok None | Error _ -> 0.0
  in
  Ok
    {
      name;
      calls;
      success_pct;
      avg_ms;
      output_truncated_count;
      avg_output_chars;
    }

let decode_tool_quality_rate_row json =
  let* name = required_nonblank_string json "name" in
  let* calls = required_nonnegative_int_field json "calls" in
  let* success_pct = required_finite_float json "success_pct" in
  Ok { name; calls; success_pct }

let decode_tool_quality_failure_cat json =
  let* category = required_string_field json "category" in
  let* count = required_nonnegative_int_field json "count" in
  Ok { category; count }

let decode_tool_quality json =
  let* _, body = unwrap_v2_or_raw json in
  let* generated_at = required_nonblank_string body "generated_at" in
  let* sampling_mode = optional_nonblank_string body "sampling_mode" in
  let sampling_mode = Option.value sampling_mode ~default:"recent_n" in
  let* total = required_nonnegative_int_field body "total" in
  let* success = required_nonnegative_int_field body "success" in
  let* failure = required_nonnegative_int_field body "failure" in
  let deferred = int_or_zero body "deferred" in
  let unsettled = int_or_zero body "unsettled" in
  let malformed = int_or_zero body "malformed" in
  let* success_rate = required_finite_float body "success_rate" in
  let* by_tool_items = optional_list_field body "by_tool" in
  let* by_tool = decode_list "by_tool" decode_tool_quality_tool_row by_tool_items in
  let* by_keeper_items = optional_list_field body "by_keeper" in
  let* by_keeper =
    decode_list "by_keeper" decode_tool_quality_rate_row by_keeper_items
  in
  let* by_runtime_items = optional_list_field body "by_runtime" in
  let* by_runtime =
    decode_list "by_runtime" decode_tool_quality_rate_row by_runtime_items
  in
  let* fc_items = optional_list_field body "failure_categories" in
  let* failure_categories =
    decode_list "failure_categories" decode_tool_quality_failure_cat fc_items
  in
  Ok
    {
      generated_at;
      sampling_mode;
      total;
      success;
      failure;
      deferred;
      unsettled;
      malformed;
      success_rate;
      by_tool;
      by_keeper;
      by_runtime;
      failure_categories;
    }

type keeper_waiting_row = {
  keeper_name : string option;
  source : string;
  waiting_on : string;
  what : string;
  wake_producer : string;
  since : float option;
  due_at : float option;
  next_action : string;
}

type keeper_waiting_inventory = {
  schema : string;
  keeper_count : int;
  waiting_keeper_count : int;
  row_count : int;
  total_row_count : int;
  oldest_age_seconds : float option;
  rows : keeper_waiting_row list;
}

let decode_keeper_waiting_row json =
  let* keeper_name = optional_nonblank_string json "keeper_name" in
  let* source = required_nonblank_string json "source" in
  let* waiting_on = required_nonblank_string json "waiting_on" in
  let* what = required_string_field json "what" in
  let* wake_producer = required_nonblank_string json "wake_producer" in
  let* since = optional_finite_float json "since" in
  let* due_at = optional_finite_float json "due_at" in
  let* next_action = required_string_field json "next_action" in
  Ok
    {
      keeper_name;
      source;
      waiting_on;
      what;
      wake_producer;
      since;
      due_at;
      next_action;
    }

let decode_keeper_waiting_inventory json =
  let* _, body = unwrap_v2_or_raw json in
  let* schema = required_nonblank_string body "schema" in
  let keeper_count = int_or_zero body "keeper_count" in
  let waiting_keeper_count = int_or_zero body "waiting_keeper_count" in
  let row_count = int_or_zero body "row_count" in
  let total_row_count = int_or_zero body "total_row_count" in
  let* oldest_age_seconds = optional_finite_float body "oldest_age_seconds" in
  let* row_items = optional_list_field body "rows" in
  let* rows = decode_list "rows" decode_keeper_waiting_row row_items in
  Ok
    {
      schema;
      keeper_count;
      waiting_keeper_count;
      row_count;
      total_row_count;
      oldest_age_seconds;
      rows;
    }

let mcp_headers ~method_ ?tool_name () =
  let base =
    [
      ("Accept", "application/json, text/event-stream");
      ("MCP-Protocol-Version", mcp_protocol_version);
      ("Mcp-Method", String.trim method_);
      ("X-Masc-Force-Json", "true");
    ]
  in
  match tool_name with
  | Some name when not (String.equal (String.trim name) "") ->
      base @ [ ("Mcp-Name", String.trim name) ]
  | Some _ | None -> base

let mcp_request_meta_json () =
  `Assoc
    [
      ("io.modelcontextprotocol/protocolVersion", `String mcp_protocol_version);
      ("io.modelcontextprotocol/clientCapabilities", `Assoc []);
    ]

let encode_mcp_tools_list_body ~id =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int id);
      ("method", `String "tools/list");
      ("params", `Assoc [ ("_meta", mcp_request_meta_json ()) ]);
    ]

let encode_mcp_tools_call_body ~id ~tool_name ~arguments =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int id);
      ("method", `String "tools/call");
      ( "params",
        `Assoc
          [
            ("name", `String (String.trim tool_name));
            ("arguments", arguments);
            ("_meta", mcp_request_meta_json ());
          ] );
    ]

type mcp_tool_schema_entry = {
  name : string;
  description : string option;
  input_schema : Yojson.Safe.t;
  required_params : string list;
  param_names : string list;
}

let decode_mcp_tool_schema_entry json =
  let* name = required_nonblank_string json "name" in
  let* description = optional_nonblank_string json "description" in
  let input_schema =
    if has_field json "inputSchema" then member "inputSchema" json
    else `Assoc []
  in
  let* required_params =
    match input_schema with
    | `Assoc _ -> optional_string_list input_schema "required"
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        Ok []
  in
  let param_names =
    match input_schema with
    | `Assoc _ -> (
        match member "properties" input_schema with
        | `Assoc props -> List.map fst props
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _
          ->
            [])
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        []
  in
  Ok { name; description; input_schema; required_params; param_names }

let extract_jsonrpc_error_opt json =
  match optional_object_field json "error" with
  | Ok (Some err_obj) ->
      let code =
        match optional_int_field err_obj "code" with
        | Ok (Some c) -> Printf.sprintf "[%d] " c
        | Ok None | Error _ -> ""
      in
      let msg =
        match optional_nonblank_string err_obj "message" with
        | Ok (Some m) -> m
        | Ok None | Error _ -> Yojson.Safe.to_string err_obj
      in
      Some (code ^ msg)
  | Ok None | Error _ -> None

let decode_mcp_tools_list json =
  match extract_jsonrpc_error_opt json with
  | Some err -> Error ("MCP tools/list error: " ^ err)
  | None ->
      let* res = required_object_field json "result" in
      let* items = required_list_field res "tools" in
      decode_list "tools" decode_mcp_tool_schema_entry items

type mcp_tool_call_result = {
  tool_name : string;
  is_error : bool;
  content_texts : string list;
  structured_json : Yojson.Safe.t option;
  raw_error : string option;
}

let decode_mcp_tools_call_result ~tool_name json =
  match extract_jsonrpc_error_opt json with
  | Some err ->
      Ok
        {
          tool_name;
          is_error = true;
          content_texts = [];
          structured_json = None;
          raw_error = Some err;
        }
  | None ->
      let* res = required_object_field json "result" in
      let is_error =
        match optional_bool_field res "isError" with
        | Ok (Some b) -> b
        | Ok None | Error _ -> false
      in
      let* content_items = optional_list_field res "content" in
      let content_texts =
        List.filter_map
          (function
            | `Assoc _ as c -> (
                match optional_string_field c "text" with
                | Ok (Some t) -> Some t
                | Ok None | Error _ -> Some (Yojson.Safe.to_string c))
            | `String s -> Some s
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ -> None)
          content_items
      in
      let structured_json =
        if has_field res "structuredContent" then
          match member "structuredContent" res with
          | `Null -> None
          | v -> Some v
        else None
      in
      Ok
        {
          tool_name;
          is_error;
          content_texts;
          structured_json;
          raw_error = None;
        }
