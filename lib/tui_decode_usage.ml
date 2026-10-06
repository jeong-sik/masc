open Tui_decode_fields

let ( let* ) = Result.bind

type provider_usage_window_kind =
  | Window_five_hour
  | Window_seven_day
  | Window_duration_minutes of int
  | Window_provider_label of string

type provider_usage_utilization =
  | Utilization_fraction of float
  | Utilization_percent of int
  | Utilization_usd of { used : float; limit : float option }

type provider_usage_window_role =
  | Role_gates_model_calls
  | Role_counts_other_use
  | Role_unclassified_limit

type provider_usage_window = {
  puw_limit_id : string option;
  puw_kind : provider_usage_window_kind;
  puw_role : provider_usage_window_role;
  puw_utilization : provider_usage_utilization;
  puw_resets_at : float option;
  puw_observed_at : float;
}

type provider_usage_state =
  | Account_not_reported_since_start
  | Account_reported_no_windows of { observed_at : float; source : string }
  | Account_reported of provider_usage_window * provider_usage_window list

type provider_usage_provider = {
  pup_id : string;
  pup_display_name : string;
}

type provider_usage_account = {
  pua_scope : string;
  pua_scope_id : string;
  pua_providers : provider_usage_provider list;
  pua_state : provider_usage_state;
}

type provider_usage_windows = {
  puws_since : float;
  puws_accounts : provider_usage_account list;
}

let required_number_field json key =
  match member key json with
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | `Null -> missing_field key
  | bad -> field_type_error key "a number" bad

let decode_provider_usage_window_kind json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "five_hour" -> Ok Window_five_hour
  | "seven_day" -> Ok Window_seven_day
  | "duration_minutes" ->
      let* minutes = required_int_field json "minutes" in
      Ok (Window_duration_minutes minutes)
  | "provider_label" ->
      let* label = required_string_field json "label" in
      Ok (Window_provider_label label)
  | other -> Error (Printf.sprintf "unknown usage window kind %S" other)

let decode_provider_usage_utilization json =
  let* unit_word = required_string_field json "unit" in
  match unit_word with
  | "fraction" ->
      let* value = required_number_field json "value" in
      Ok (Utilization_fraction value)
  | "percent" ->
      let* value = required_int_field json "value" in
      Ok (Utilization_percent value)
  | "usd" ->
      let* used = required_number_field json "value" in
      let* limit = required_nullable_float_field json "limit" in
      if not (Float.is_finite used) || used < 0.0 then
        Error "invalid USD usage amount"
      else if Option.fold ~none:false
          ~some:(fun limit -> not (Float.is_finite limit) || limit <= 0.0) limit then
        Error "invalid USD usage limit"
      else Ok (Utilization_usd { used; limit })
  | other -> Error (Printf.sprintf "unknown usage unit %S" other)

let decode_provider_usage_window_role json =
  let* role = required_string_field json "role" in
  match role with
  | "gates_model_calls" -> Ok Role_gates_model_calls
  | "counts_other_use" -> Ok Role_counts_other_use
  | "unclassified_limit" -> Ok Role_unclassified_limit
  | other -> Error (Printf.sprintf "unknown usage window role %S" other)

let decode_provider_usage_window json =
  let* limit_id = required_member json "limit_id" in
  let* puw_limit_id =
    match limit_id with
    | `Null -> Ok None
    | `String id -> Ok (Some id)
    | bad -> field_type_error "limit_id" "a string or null" bad
  in
  let* kind = required_object_field json "window" in
  let* puw_kind = decode_provider_usage_window_kind kind in
  let* puw_role = decode_provider_usage_window_role json in
  let* utilization = required_object_field json "utilization" in
  let* puw_utilization = decode_provider_usage_utilization utilization in
  let* resets_at = required_member json "resets_at" in
  let* puw_resets_at =
    match resets_at with
    | `Null -> Ok None
    | `Int at -> Ok (Some (Float.of_int at))
    | `Float at -> Ok (Some at)
    | bad -> field_type_error "resets_at" "a number or null" bad
  in
  let* puw_observed_at = required_number_field json "observed_at" in
  Ok
    { puw_limit_id
    ; puw_kind
    ; puw_role
    ; puw_utilization
    ; puw_resets_at
    ; puw_observed_at
    }

let decode_provider_usage_account json =
  let* pua_scope = required_string_field json "scope" in
  let* pua_scope_id = required_string_field json "scope_id" in
  let* provider_items = required_list_field json "providers" in
  let* pua_providers =
    decode_list "providers"
      (fun provider ->
        let* pup_id = required_string_field provider "id" in
        let* pup_display_name = required_string_field provider "display_name" in
        Ok { pup_id; pup_display_name })
      provider_items
  in
  let* state = required_string_field json "state" in
  let* window_items = required_list_field json "windows" in
  let* windows = decode_list "windows" decode_provider_usage_window window_items in
  let* pua_state =
    match (state, windows) with
    | "reported", first :: rest -> Ok (Account_reported (first, rest))
    | "reported", [] ->
        Error (Printf.sprintf "account %S is reported with no window" pua_scope)
    | "not_reported_since_start", [] -> Ok Account_not_reported_since_start
    | "reported_no_windows", [] ->
        let* observed_at = required_number_field json "observed_at" in
        let* source = required_string_field json "source" in
        Ok (Account_reported_no_windows { observed_at; source })
    | "not_reported_since_start", _ :: _ ->
        Error
          (Printf.sprintf "account %S carries windows but is not reported"
             pua_scope)
    | other, _ -> Error (Printf.sprintf "unknown usage state %S" other)
  in
  Ok { pua_scope; pua_scope_id; pua_providers; pua_state }

let decode_provider_usage_windows json =
  let* puws_since = required_number_field json "provider_usage_windows_since" in
  let* items = required_list_field json "provider_usage_windows" in
  let* puws_accounts =
    decode_list "provider_usage_windows" decode_provider_usage_account items
  in
  Ok { puws_since; puws_accounts }

type provider_usage_history_point = {
  puhp_scope_id : string;
  puhp_kind : string;
  puhp_limit_id : string option;
  puhp_unit : provider_usage_utilization;
  puhp_observed_at : float;
}

type provider_usage_empty_report = {
  puhe_scope_id : string;
  puhe_observed_at : float;
}

type provider_usage_history = {
  puh_days : int;
  puh_generated_at : float;
  puh_unreadable_reports : int;
  puh_points : provider_usage_history_point list;
  puh_reported_no_windows : provider_usage_empty_report list;
}

let decode_provider_usage_history_point json =
  let* puhp_scope_id = required_string_field json "scope_id" in
  let* puhp_kind = required_string_field json "kind" in
  let* puhp_limit_id = required_nullable_string_field json "limit_id" in
  let* puhp_observed_at = required_number_field json "observed_at" in
  let* unit = required_string_field json "unit" in
  let* puhp_unit =
    match unit with
    | "fraction" ->
        let* value = required_number_field json "value" in
        if Float.is_finite value then Ok (Utilization_fraction value)
        else Error "provider usage history: non-finite fraction"
    | "percent" ->
        let* value = required_int_field json "value" in
        Ok (Utilization_percent value)
    | "usd" -> decode_provider_usage_utilization json
    | _ -> Error ("provider usage history: unknown unit " ^ unit)
  in
  Ok { puhp_scope_id; puhp_kind; puhp_limit_id; puhp_unit; puhp_observed_at }

let decode_provider_usage_history json =
  let* puh_days = required_int_field json "days" in
  if not (List.mem puh_days [ 1; 7; 14 ]) then
    Error "provider usage history: unsupported day window"
  else
    let* puh_generated_at = required_number_field json "generated_at" in
    let* sampling = required_string_field json "sampling" in
    if sampling <> "latest_provider_report_per_utc_day" then
      Error "provider usage history: unknown sampling contract"
    else
      let* puh_unreadable_reports =
        required_int_field json "unreadable_reports"
      in
      let* points = required_list_field json "points" in
      let* puh_points =
        decode_list "points" decode_provider_usage_history_point points
      in
      let* empty_reports = required_list_field json "reported_no_windows" in
      let* puh_reported_no_windows = decode_list "reported_no_windows" (fun json ->
        let* puhe_scope_id = required_string_field json "scope_id" in
        let* puhe_observed_at = required_number_field json "observed_at" in
        Ok { puhe_scope_id; puhe_observed_at }) empty_reports in
      Ok { puh_days; puh_generated_at; puh_unreadable_reports; puh_points; puh_reported_no_windows }

type keeper_usage_coverage =
  | Keeper_usage_complete
  | Keeper_usage_partial of { malformed_rows : int; unread_turn_rows : int }
  | Keeper_usage_failed of string

type keeper_usage_row = {
  kur_name : string;
  kur_turn_samples : int;
  kur_tokens : int option;
  kur_cost_usd : float option;
  kur_tokens_reported : int;
  kur_tokens_missing : int;
  kur_cost_reported : int;
  kur_cost_missing : int;
  kur_coverage : keeper_usage_coverage;
}

type keeper_usage_freshness =
  | Keeper_usage_fresh
  | Keeper_usage_stale of { age_s : float; last_error : string option }

type keeper_usage_window =
  | Keeper_usage_loading
  | Keeper_usage_window of {
      kuw_generated_at : float;
      kuw_window_minutes : int;
      kuw_rows : keeper_usage_row list;
      kuw_freshness : keeper_usage_freshness;
    }

let decode_keeper_usage_row json =
  let* kur_name = required_string_field json "keeper_name" in
  let* kur_turn_samples = required_int_field json "sample_count" in
  let* kur_tokens = required_nullable_int_field json "total_tokens" in
  let* kur_cost_usd = required_nullable_float_field json "total_cost_usd" in
  let* kur_tokens_reported = required_int_field json "tokens_reported_samples" in
  let* tokens_unreported = required_int_field json "tokens_unreported_samples" in
  let* tokens_unread = required_int_field json "tokens_unread_samples" in
  let* kur_cost_reported = required_int_field json "cost_reported_samples" in
  let* cost_unreported = required_int_field json "cost_unreported_samples" in
  let* cost_unread = required_int_field json "cost_unread_samples" in
  let* metrics_read = required_object_field json "metrics_read" in
  let* read_state = required_string_field metrics_read "state" in
  let* kur_coverage =
    match read_state with
    | "read" ->
        let* malformed_rows = required_int_field metrics_read "malformed_rows" in
        let* unread_turn_rows = required_int_field metrics_read "unread_turn_rows" in
        if malformed_rows < 0 || unread_turn_rows < 0 then
          Error "keeper usage unread row counts must be nonnegative"
        else Ok (if malformed_rows = 0 && unread_turn_rows = 0 then Keeper_usage_complete
            else Keeper_usage_partial { malformed_rows; unread_turn_rows })
    | "failed" ->
        let* reason = required_string_field metrics_read "reason" in
        Ok (Keeper_usage_failed reason)
    | state -> Error ("unknown keeper usage read state: " ^ state)
  in
  Ok
    { kur_name; kur_turn_samples; kur_tokens; kur_cost_usd;
      kur_tokens_reported;
      kur_tokens_missing = tokens_unreported + tokens_unread;
      kur_cost_reported;
      kur_cost_missing = cost_unreported + cost_unread;
      kur_coverage }

let decode_keeper_usage_window json =
  let* cache = required_object_field json "cache" in
  let* cache_word = required_string_field cache "state" in
  let* cache_state =
    match Dashboard_cache_wire.of_string cache_word with
    | Some state -> Ok state
    | None -> Error ("unknown keeper usage cache state: " ^ cache_word)
  in
  let* last_error = optional_string_field cache "last_error" in
  match Json_util.assoc_member_opt "state" json, cache_state with
  | Some (`String "loading"), Dashboard_cache_wire.Cache_warming ->
      (match last_error with
       | None -> Ok Keeper_usage_loading
       | Some detail -> Error ("Keeper usage computation failed: " ^ detail))
  | None, (Dashboard_cache_wire.Cache_fresh | Dashboard_cache_wire.Cache_stale_refreshing) ->
      let* kuw_freshness =
        match cache_state with
        | Dashboard_cache_wire.Cache_fresh -> Ok Keeper_usage_fresh
        | Dashboard_cache_wire.Cache_stale_refreshing ->
            let* age_s = required_number_field cache "age_s" in
            Ok (Keeper_usage_stale { age_s; last_error })
        | Dashboard_cache_wire.Cache_warming -> Error "keeper usage still warming"
      in
      let* kuw_generated_at = required_number_field json "generated_at" in
      let* () =
        match Ptime.of_float_s kuw_generated_at with
        | Some _ -> Ok ()
        | None -> Error "keeper usage generated_at is outside the supported timestamp range"
      in
      let* kuw_window_minutes = required_int_field json "window_minutes" in
      let* rows = required_list_field json "keepers" in
      let* kuw_rows = decode_list "keepers" decode_keeper_usage_row rows in
      Ok (Keeper_usage_window
        { kuw_generated_at; kuw_window_minutes; kuw_rows; kuw_freshness })
  | Some (`String state), _ -> Error ("unknown keeper usage state or cache: " ^ state ^ "/" ^ cache_word)
  | Some _, _ -> Error "keeper usage state must be a string"
  | None, Dashboard_cache_wire.Cache_warming -> Error "keeper usage warming cache has no loading placeholder"
