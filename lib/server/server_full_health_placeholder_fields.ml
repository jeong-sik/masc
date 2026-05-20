(* /health?full=1 cached-field placeholder builders.

   The full-health snapshot is computed off the hot path and cached
   for 2s. When the cache is cold (boot, refresh in flight, error), a
   placeholder payload with [status="warming"] / ["error"] is served
   under the same field names so the dashboard doesn't have to handle
   "missing key" vs "present-but-warming" separately.

   Extracted from [Server_routes_http_runtime] (godfile decomp). Pure
   builders + a field-membership predicate. No I/O, no state. *)

let full_health_cached_field_names =
  [ "feature_flags"
  ; "keeper_fibers"
  ; "keeper_fd_pressure"
  ; "fd_accountant"
  ; "keeper_fleet_safety"
  ; "keeper_reaction_ledger"
  ; "paused_keepers"
  ; "cdal"
  ; "keeper_config_parse_error_count"
  ; "keeper_config_parse_errors"
  ; "keeper_config_unknown_key_count"
  ; "keeper_config_unknown_keys"
  ; "keeper_config_schema_status"
  ; "keeper_config_schema_blocking"
  ; "keeper_config_schema_terminal_reason"
  ; "keeper_config_operator_action_required"
  ; "lazy_task_boot_guard_fires_total"
  ]
;;

let full_health_field_is_cached name =
  List.exists (String.equal name) full_health_cached_field_names
;;

let full_health_component_placeholder ?error ~status component =
  let error_fields =
    match error with
    | Some error -> [ "error", `String error ]
    | None -> []
  in
  `Assoc
    ([ "component", `String component
     ; "status", `String status
     ; "component_timed_out", `Bool false
     ]
     @ error_fields)
;;

let full_health_placeholder_fields ?error ?(status = "warming") () =
  [ ( "feature_flags"
    , full_health_component_placeholder ?error ~status "feature_flags" )
  ; "keeper_fibers", `Int 0
  ; ( "keeper_fd_pressure"
    , full_health_component_placeholder ?error ~status "keeper_fd_pressure" )
  ; ( "fd_accountant"
    , full_health_component_placeholder ?error ~status "fd_accountant" )
  ; ( "keeper_fleet_safety"
    , full_health_component_placeholder ?error ~status "keeper_fleet_safety" )
  ; ( "keeper_reaction_ledger"
    , full_health_component_placeholder ?error ~status "keeper_reaction_ledger" )
  ; ( "paused_keepers"
    , `Assoc
        [ "status", `String status
        ; "count", `Int 0
        ; "names", `List []
        ; "component_timed_out", `Bool false
        ] )
  ; "cdal", full_health_component_placeholder ?error ~status "cdal"
  ; "keeper_config_parse_error_count", `Int 0
  ; "keeper_config_parse_errors", `List []
  ; "keeper_config_unknown_key_count", `Int 0
  ; "keeper_config_unknown_keys", `List []
  ; "keeper_config_schema_status", `String status
  ; "keeper_config_schema_blocking", `Bool false
  ; "keeper_config_schema_terminal_reason", `String "snapshot_not_ready"
  ; "keeper_config_operator_action_required", `Bool false
  ; "lazy_task_boot_guard_fires_total", `Int 0
  ]
;;

let cached_full_health_fields = function
  | `Assoc fields ->
    List.filter (fun (name, _) -> full_health_field_is_cached name) fields
  | json ->
    [ ( "full_health_payload"
      , `Assoc [ "status", `String "unexpected_payload"; "payload", json ] )
    ]
;;
