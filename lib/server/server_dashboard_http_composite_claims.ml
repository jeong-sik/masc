(** Server_dashboard_http_composite — Composite fleet snapshot,
    runtime attention, and recommended-actions JSON builders.

    Extracted from server_dashboard_http.ml during godfile decomposition.
    Depends on Server_dashboard_http_json_utils, Server_dashboard_compact_receipt_json,
    Server_dashboard_fleet_readiness, and various Keeper modules. *)


let json_member = Server_dashboard_http_json_utils.json_member
let json_string key json = Json_util.get_string json key
let json_float key json = Json_util.get_float json key
let json_bool key json = Json_util.get_bool json key

let compact_receipt_error_json = Server_dashboard_compact_receipt_json.compact_receipt_error_json
let compact_receipt_runtime_json = Server_dashboard_compact_receipt_json.compact_receipt_runtime_json

let json_number = Server_dashboard_http_json_utils.json_number

let composite_config_drift_json ~config ~keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Ok (Some meta) ->
    let sources = Keeper_status_bridge.source_provenance config meta in
    let override_fields =
      List.map Keeper_status_bridge_override.field_name sources.overrides
    in
    let runtime_drift = Keeper_status_bridge_override.runtime_drift sources.overrides in
    let default_runtime_id, live_runtime_id =
      match runtime_drift with
      | Some { default; live } -> Some default, Some live
      | None -> None, None
    in
    let runtime_override = Option.is_some runtime_drift in
    `Assoc
      [ "present", `Bool true
      ; "status", `String (if runtime_override then "drift" else "ok")
      ; "runtime_override", `Bool runtime_override
      ; "override_fields", Json_util.json_string_list override_fields
      ; "default_runtime_id", Json_util.string_opt_to_json default_runtime_id
      ; "live_runtime_id", Json_util.string_opt_to_json live_runtime_id
      ; "active_config_root", `String (Keeper_status_bridge.active_config_root sources)
      ]
  | Ok None ->
    `Assoc
      [ "present", `Bool false
      ; "status", `String "keeper_missing"
      ; "runtime_override", `Bool false
      ; "override_fields", `List []
      ; "default_runtime_id", `Null
      ; "live_runtime_id", `Null
      ; "active_config_root", `Null
      ]
  | Error message ->
    `Assoc
      [ "present", `Bool false
      ; "status", `String "read_error"
      ; "error", `String message
      ; "runtime_override", `Bool false
      ; "override_fields", `List []
      ; "default_runtime_id", `Null
      ; "live_runtime_id", `Null
      ; "active_config_root", `Null
      ]
;;

let composite_execution_receipt_json ~(config : Workspace.config) ~keeper_name =
  let config_drift = composite_config_drift_json ~config ~keeper_name in
  match Keeper_execution_receipt.latest_json config keeper_name with
  | None ->
    `Assoc
      [ "latest_receipt_present", `Bool false
      ; "runtime_lane_observation", `Null
      ; "recorded_at", `Null
      ; "outcome", `Null
      ; "terminal_reason_code", `Null
      ; "operator_disposition", `Null
      ; "operator_disposition_reason", `Null
      ; "model_used", `Null
      ; "stop_reason", `Null
      ; "completion_contract_result", `Null
      ; "duration_ms", `Null
      ; "error", `Null
      ; "runtime", `Null
      ; "config_drift", config_drift
      ]
  | Some receipt ->
    let action_radius = json_member "action_radius" receipt in
    `Assoc
      [ "latest_receipt_present", `Bool true
      ; ( "runtime_lane_observation"
        , Keeper_execution_receipt.runtime_lane_observation_of_receipt_json receipt
          |> Keeper_execution_receipt.runtime_lane_observation_to_yojson )
      ; "recorded_at", Json_util.string_opt_to_json (json_string "recorded_at" receipt)
      ; "outcome", Json_util.string_opt_to_json (json_string "outcome" receipt)
      ; ( "terminal_reason_code"
        , Json_util.string_opt_to_json (json_string "terminal_reason_code" receipt) )
      ; ( "operator_disposition"
        , Json_util.string_opt_to_json (json_string "operator_disposition" receipt) )
      ; ( "operator_disposition_reason"
        , Json_util.string_opt_to_json (json_string "operator_disposition_reason" receipt)
        )
      ; "model_used", `Null
      ; "stop_reason", Json_util.string_opt_to_json (json_string "stop_reason" receipt)
      ; ( "completion_contract_result"
        , Json_util.string_opt_to_json (json_string "completion_contract_result" receipt) )
      ; ( "duration_ms"
        , Json_util.float_opt_to_json (json_float "duration_ms" action_radius) )
      ; "error", compact_receipt_error_json receipt
      ; "runtime", compact_receipt_runtime_json receipt
      ; "config_drift", config_drift
      ]
;;

let lower_string_opt =
  Option.map (fun value -> String.lowercase_ascii (String.trim value))
;;

let string_opt_is_any value candidates =
  match lower_string_opt value with
  | Some value -> List.mem value candidates
  | None -> false
;;

let string_opt_present value =
  match Option.map String.trim value with
  | Some value -> value <> ""
  | None -> false
;;

let json_string_eq key json expected =
  match json_string key json with
  | Some value -> String.equal value expected
  | None -> false
;;

let composite_latest_activity_epoch snapshot execution =
  let live_turn_progress_epoch =
    match json_member "live_turn" snapshot with
    | `Assoc _ as live_turn -> json_number "last_progress_at" live_turn
    | _ -> None
  in
  let last_outcome_epoch =
    match json_member "last_outcome" snapshot with
    | `Assoc _ as last_outcome -> json_number "ended_at" last_outcome
    | _ -> None
  in
  let receipt_epoch =
    match json_string "recorded_at" execution with
    | Some raw -> Masc_domain.parse_iso8601_opt raw
    | None -> None
  in
  [ live_turn_progress_epoch; last_outcome_epoch; receipt_epoch ]
  |> List.filter_map Fun.id
  |> function
  | [] -> None
  | first :: rest -> Some (List.fold_left max first rest)
;;

let composite_snapshot_is_idle snapshot =
  let decision = json_member "decision" snapshot in
  let runtime = json_member "runtime" snapshot in
  json_string_eq "turn_phase" snapshot "idle"
  && json_string_eq "stage" decision "undecided"
  && json_string_eq "state" runtime "idle"
;;

let composite_execution_config_blocked execution =
  string_opt_is_any
    (json_string "operator_disposition_reason" execution)
    [ "config_invalid"; "authorization_refused" ]
;;

let composite_execution_config_drift execution =
  match json_member "config_drift" execution with
  | `Assoc _ as config_drift ->
    Option.value ~default:false (json_bool "runtime_override" config_drift)
  | _ -> false
;;

let keeper_activation_readiness_json = Server_dashboard_fleet_readiness.keeper_activation_readiness_json

let composite_execution_blocked execution =
  (match json_string "terminal_reason_code" execution with
      | Some terminal ->
        not (String.equal terminal "")
        && Keeper_turn_disposition.requires_attention
             (Keeper_turn_disposition.of_wire terminal)
      | None -> false)
  ||
  match json_member "error" execution with
  | `Assoc _ as error -> string_opt_present (json_string "kind" error)
  | _ -> false
;;

let composite_execution_receipt_present execution =
  Option.value ~default:false (json_bool "latest_receipt_present" execution)
;;

let composite_execution_receipt_epoch execution =
  match json_string "recorded_at" execution with
  | Some raw -> Masc_domain.parse_iso8601_opt raw
  | None -> None
;;

let composite_live_turn_started_epoch snapshot =
  match json_member "live_turn" snapshot with
  | `Assoc _ as live_turn -> json_number "started_at" live_turn
  | _ -> None
;;

let composite_live_turn_last_progress_epoch snapshot =
  match json_member "live_turn" snapshot with
  | `Assoc _ as live_turn -> json_number "last_progress_at" live_turn
  | _ -> None
;;

let composite_execution_current_for_runtime_state ~snapshot ~execution =
  if not (composite_execution_receipt_present execution)
  then true
  else (
    let is_live = Option.value ~default:false (json_bool "is_live" snapshot) in
    if not is_live
    then true
    else
      match
        ( composite_live_turn_started_epoch snapshot,
          composite_execution_receipt_epoch execution )
      with
      | Some live_started_at, Some receipt_at -> receipt_at >= live_started_at
      | _ -> false)
;;

(* The closed set of [runtime_attention.state] wire values.
   [composite_runtime_attention] judges a keeper in the registry and yields one
   of the first five. [Server_dashboard_http_keeper_api.offline_keeper_composite_json]
   answers for a keeper that has meta on disk but no registry entry and yields
   [Attention_paused] or [Attention_offline]. *)
type runtime_attention_state =
  | Attention_blocked
  | Attention_stop_requested
  | Attention_idle_stale
  | Attention_stale
  | Attention_ok
  | Attention_paused
  | Attention_offline

let runtime_attention_state_to_wire = function
  | Attention_blocked -> "blocked"
  | Attention_stop_requested -> "stop_requested"
  | Attention_idle_stale -> "idle_stale"
  | Attention_stale -> "stale"
  | Attention_ok -> "ok"
  | Attention_paused -> "paused"
  | Attention_offline -> "offline"
;;

type composite_runtime_attention =
  { cra_is_live : bool
  ; cra_fiber_stop_requested : bool
  ; cra_idle_attention : bool
  ; cra_blocked : bool
  ; cra_execution_current : bool
  ; cra_stale_execution_receipt : bool
  ; cra_live_turn_started_at : float option
  ; cra_live_turn_last_progress_at : float option
  ; cra_needs_attention : bool
  ; cra_reason : string option
  ; cra_state : runtime_attention_state
  }

let composite_runtime_attention ~snapshot ~execution =
  let is_live = Option.value ~default:false (json_bool "is_live" snapshot) in
  let fiber_stop_requested =
    Option.value ~default:false (json_bool "fiber_stop_flag" snapshot)
  in
  let latest = composite_latest_activity_epoch snapshot execution in
  let now = Unix.gettimeofday () in
  let stale_long_enough =
    match latest with
    | Some ts -> now -. ts >= 600.0
    | None -> not is_live
  in
  let idle_attention =
    is_live && composite_snapshot_is_idle snapshot && stale_long_enough
  in
  let execution_current =
    composite_execution_current_for_runtime_state ~snapshot ~execution
  in
  let stale_execution_receipt =
    composite_execution_receipt_present execution && not execution_current
  in
  let blocked = execution_current && composite_execution_blocked execution in
  let stale_without_live_turn = (not is_live) && stale_long_enough in
  let needs_attention =
    blocked || fiber_stop_requested || stale_without_live_turn || idle_attention
  in
  let execution_reason =
    if not execution_current
    then None
    else if not blocked
    then None
    else
      (match json_string "operator_disposition_reason" execution with
       | Some value -> String_util.trim_nonempty value
       | _ ->
         (match json_string "terminal_reason_code" execution with
          | Some value -> String_util.trim_nonempty value
          | _ when needs_attention && composite_execution_config_drift execution ->
            Some "keeper_runtime_override_drift"
          | _ -> Some "runtime_blocked"))
  in
  let reason =
    match execution_reason with
    | Some _ as reason -> reason
    | None when fiber_stop_requested -> Some "fiber_stop_requested"
    | None when idle_attention -> Some "idle_composite"
    | None when stale_without_live_turn -> Some "not_live"
    | None -> None
  in
  let state =
    if blocked
    then Attention_blocked
    else if fiber_stop_requested
    then Attention_stop_requested
    else if idle_attention
    then Attention_idle_stale
    else if stale_without_live_turn
    then Attention_stale
    else Attention_ok
  in
  { cra_is_live = is_live
  ; cra_fiber_stop_requested = fiber_stop_requested
  ; cra_idle_attention = idle_attention
  ; cra_blocked = blocked
  ; cra_execution_current = execution_current
  ; cra_stale_execution_receipt = stale_execution_receipt
  ; cra_live_turn_started_at = composite_live_turn_started_epoch snapshot
  ; cra_live_turn_last_progress_at = composite_live_turn_last_progress_epoch snapshot
  ; cra_needs_attention = needs_attention
  ; cra_reason = reason
  ; cra_state = state
  }
;;

let composite_runtime_attention_json attention ~snapshot =
  `Assoc
    [ "state", `String (runtime_attention_state_to_wire attention.cra_state)
    ; "needs_attention", `Bool attention.cra_needs_attention
    ; "blocked", `Bool attention.cra_blocked
    ; "fiber_stop_requested", `Bool attention.cra_fiber_stop_requested
    ; "reason", Json_util.string_opt_to_json attention.cra_reason
    ; "raw_phase", Json_util.string_opt_to_json (json_string "phase" snapshot)
    ; "is_live", `Bool attention.cra_is_live
    ; "execution_current", `Bool attention.cra_execution_current
    ; "stale_execution_receipt", `Bool attention.cra_stale_execution_receipt
    ; "live_turn_started_at",
      Json_util.float_opt_to_json attention.cra_live_turn_started_at
    ; "live_turn_last_progress_at",
      Json_util.float_opt_to_json attention.cra_live_turn_last_progress_at
    ; ( "source"
      , `String
          (if attention.cra_blocked
           then "execution_receipt"
           else if attention.cra_stale_execution_receipt
           then "live_turn"
           else if attention.cra_fiber_stop_requested
           then "registry_fiber_stop"
           else "composite_snapshot") )
    ]
;;
