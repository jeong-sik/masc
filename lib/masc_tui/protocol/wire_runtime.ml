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
let setup_accounts_login_path = "/api/v1/setup/accounts/login"

let setup_accounts_login_status_path ~login_id =
  "/api/v1/setup/accounts/login/" ^ percent_encode login_id

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

let dashboard_tools_path ?keeper () =
  match keeper with
  | None -> "/api/v1/dashboard/tools"
  | Some k -> "/api/v1/dashboard/tools?keeper=" ^ percent_encode k

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
let browser_lane_path = "/api/v1/dashboard/browser-lane/clients"
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
      | Some c -> c
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

type exact_lane_run = {
  run_id : string;
  lane : string;
  status : string;
  started_at_unix : float option;
  finished_at_unix : float option;
  summary : string option;
}

let decode_exact_lane_run json =
  let* run_id = required_nonblank_string json "run_id" in
  let* lane = required_nonblank_string json "lane" in
  let* status = required_nonblank_string json "status" in
  let* started_at_unix = decode_optional_timestamp_unix json "started_at" in
  let* finished_at_unix = decode_optional_timestamp_unix json "finished_at" in
  let* summary_opt = optional_nonblank_string json "summary" in
  let* detail_opt = optional_nonblank_string json "detail" in
  let* subject_opt = optional_nonblank_string json "subject_id" in
  let summary =
    match summary_opt with
    | Some _ as s -> s
    | None -> (
        match (subject_opt, detail_opt) with
        | Some sub, Some det -> Some (sub ^ " · " ^ det)
        | Some sub, None -> Some sub
        | None, Some det -> Some det
        | None, None -> None)
  in
  Ok { run_id; lane; status; started_at_unix; finished_at_unix; summary }

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

type connector_connection =
  | Connector_connected
  | Connector_connected_unavailable
  | Connector_disconnected
  | Connector_offline
  | Connector_stale

type connector_row = {
  connector_id : string;
  display_name : string;
  connection : connector_connection;
  channel : string option;
  error : string option;
  binding_count : int;
}

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
  let* bindings = optional_list_field json "configured_bindings" in
  Ok
    {
      connector_id;
      display_name;
      connection;
      channel;
      error;
      binding_count = List.length bindings;
    }

let decode_connectors json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "connectors" in
  decode_list "connectors" decode_connector_row items

type browser_lane_status = {
  ok : bool;
  available : bool;
  inventory_complete : bool;
  client_count : int;
  issue_count : int;
  automatic_browse_ok : bool;
  detail : string option;
}

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
      }
  else
    let* data = required_object_field body "data" in
    let* clients = required_list_field data "clients" in
    let* issues = required_list_field data "inventoryIssues" in
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
      }

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
