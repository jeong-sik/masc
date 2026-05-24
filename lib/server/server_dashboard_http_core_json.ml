(** JSON helpers + projection-diagnostic field readers + operator
    cache JSON wrapper, extracted from server_dashboard_http_core.ml. *)



let json_assoc_field_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let json_assoc_string_opt key json =
  match json_assoc_field_opt key json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let json_assoc_int_opt key json =
  match json_assoc_field_opt key json with
  | Some (`Int value) -> Some value
  | Some (`Float value) -> Some (int_of_float value)
  | _ -> None
;;

let projection_diagnostics_fields json =
  match json_assoc_field_opt "projection_diagnostics" json with
  | Some (`Assoc fields) -> fields
  | _ -> []
;;

let projection_diagnostics_field json key =
  List.assoc_opt key (projection_diagnostics_fields json)
;;

let operator_generated_at_iso json =
  match projection_diagnostics_field json "generated_at" with
  | Some (`String value) -> value
  | _ ->
    (match json_assoc_string_opt "generated_at" json with
     | Some value -> value
     | None -> Masc_domain.now_iso ())
;;

let dashboard_request_timeout_s = Server_dashboard_http_core_cache.dashboard_request_timeout_s
let operator_refresh_interval_s = Server_dashboard_http_core_operator.operator_refresh_interval_s

let operator_cache_json ?cache_key ~scope json =
  let diagnostic_field key =
    match projection_diagnostics_field json key with
    | Some value -> value
    | None -> `Null
  in
  let cache_state =
    match projection_diagnostics_field json "cache_state" with
    | Some (`String value) -> value
    | _ -> "request_swr_or_inline_compute"
  in
  `Assoc
    [ "scope", `String scope
    ; "cache_state", `String cache_state
    ; "projection_surface", diagnostic_field "surface"
    ; "last_success_at", diagnostic_field "last_success_at"
    ; "last_attempt_at", diagnostic_field "last_attempt_at"
    ; "last_error_at", diagnostic_field "last_error_at"
    ; "stale_reason", diagnostic_field "stale_reason"
    ; "stale_age_ms", diagnostic_field "stale_age_ms"
    ; "request_cache_key", Json_util.string_opt_to_json cache_key
    ; "request_cache_ttl_s", `Float 5.0
    ; "request_timeout_s", `Float Server_dashboard_http_core_cache.dashboard_request_timeout_s
    ; ( "background_refresh_interval_s"
      , `Float Server_dashboard_http_core_operator.operator_refresh_interval_s )
    ; "policy", `String "cached_surface plus HTTP stale-while-revalidate"
    ]
;;
