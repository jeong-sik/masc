(** Server_dashboard_http_composite — Composite fleet snapshot,
    runtime attention, and recommended-actions JSON builders.

    Extracted from server_dashboard_http.ml during godfile decomposition.
    Depends on Server_dashboard_http_json_utils, Server_dashboard_compact_receipt_json,
    Server_dashboard_fleet_readiness, and various Keeper modules. *)


let json_member = Server_dashboard_http_json_utils.json_member
let json_string key json = Json_util.get_string json key
let json_int key json = Json_util.get_int json key
let json_float key json = Json_util.get_float json key
let json_bool key json = Json_util.get_bool json key

let compact_receipt_error_json = Server_dashboard_compact_receipt_json.compact_receipt_error_json
let compact_receipt_runtime_json = Server_dashboard_compact_receipt_json.compact_receipt_runtime_json

let json_number = Server_dashboard_http_json_utils.json_number
let json_assoc = Server_dashboard_http_json_utils.json_assoc
let string_has_prefix = Server_dashboard_http_json_utils.string_has_prefix

let tool_call_output_text json =
  match json_member "output" json with
  | `String value -> Some value
  | `Assoc _ as output -> (
    match json_assoc "_blob" output with
    | Some blob -> json_string "preview" blob
    | None -> None)
  | _ -> None
;;

let parse_tool_call_output json =
  match tool_call_output_text json with
  | None -> None
  | Some output -> (
    match Safe_ops.parse_json_safe ~context:"composite.tool_call_output" output with
    | Ok parsed -> Some parsed
    | Error _ -> None)
;;

let claim_status_of_output output =
  let result = Option.value ~default:"" (json_string "result" output) |> String.trim in
  match json_assoc "claimed_task" output with
  | Some _ -> "claimed"
  | None when string_has_prefix ~prefix:"No eligible tasks" result -> "no_eligible"
  | None when string_has_prefix ~prefix:"No unclaimed tasks" result -> "no_unclaimed"
  | None when string_has_prefix ~prefix:"Error:" result -> "error"
  | None when result = "" -> "unknown"
  | None -> "observed"
;;

let composite_claim_attempt_absent =
  `Assoc
    [ "present", `Bool false
    ; "source", `String "keeper_task_claim_tool_call"
    ; "status", `String "not_observed"
    ; "result", `Null
    ; "claimed_task_id", `Null
    ; "claimed_goal_id", `Null
    ]
;;

(* Rows one keeper's claim lookup considers, and the fleet-wide window that
   covers it. [read_recent ~keeper_name ~n] over-scans by
   [read_over_scan_factor] before its keeper filter, so a shared read of
   [claim_window_rows] covers exactly what a per-keeper [read_recent ~n:100]
   would have read. *)
let claim_rows_per_keeper = 100

let claim_window_rows =
  claim_rows_per_keeper * Keeper_tool_call_log.read_over_scan_factor
;;

(* One fleet-wide tail of tool-call rows, read once and shared by every keeper
   in the same composite envelope.

   [composite_claim_attempt_json] used to read its own window per keeper. Every
   such read pulls [claim_window_rows] rows from the single shared tool-call
   store, so the fleet envelope — which calls this once per keeper — read and
   parsed the same rows once per keeper: identical bytes, identical parse
   trees, N times, to answer N questions one read answers for all of them. On
   the store this was measured against, rows average 6.8 KB.

   Constructed only by [read_claim_window] so a caller cannot pass a list that
   was filtered, reordered, or read with a different window. *)
type claim_window = Claim_window of Yojson.Safe.t list

let read_claim_window () =
  Claim_window (Keeper_tool_call_log.read_recent_rows ~n:claim_window_rows ())
;;

let row_is_task_claim json =
  (* The tool name is a string on the wire; [Keeper_tooling.Name] is the typed
     vocabulary that owns it, so the comparison goes through the variant rather
     than a literal. A renamed or removed constructor then fails to compile
     instead of silently matching nothing. *)
  match Option.bind (json_string "tool" json) Keeper_tooling.Name.of_string with
  | Some Keeper_tooling.Name.Task_claim -> true
  | Some
      ( Keeper_tooling.Name.Broadcast
      | Keeper_tooling.Name.Task_create
      | Keeper_tooling.Name.Task_done
      | Keeper_tooling.Name.Task_cancel
      | Keeper_tooling.Name.Task_release
      | Keeper_tooling.Name.Tasks_audit
      | Keeper_tooling.Name.Tasks_list )
  | None -> false
;;

(* The latest claim, not the first one a scan meets.

   [Keeper_tool_call_log.read_recent] and [read_recent_rows] both return rows
   oldest-first (dated_jsonl.mli: "the newest [n] entries in chronological
   order (oldest first)"), so the [List.find_opt] this replaces returned the
   *oldest* claim in the window. It went unnoticed because
   [filter_rows_for_keeper] rings a busy keeper down to its last
   [claim_rows_per_keeper] rows, which usually trims the older claim away and
   leaves the newer one to be found by accident; a quiet keeper keeps both and
   reports the superseded task. Measured on one live Keeper (46 rows in
   window, nothing trimmed) reported task-305 while it had claimed task-306.
   See #28437.

   Ordering is row order, which is what the store documents and what the
   previous code relied on. The row's own [ts] is deliberately not consulted:
   that would make append order and timestamp order two competing authorities
   for "latest". *)
let latest_task_claim_row (Claim_window rows) ~keeper_name =
  Keeper_tool_call_log.filter_rows_for_keeper
    ~keeper_name
    ~n:claim_rows_per_keeper
    rows
  |> List.fold_left
       (fun latest json -> if row_is_task_claim json then Some json else latest)
       None
;;

let composite_claim_attempt_json ~claim_window ~keeper_name =
  match latest_task_claim_row claim_window ~keeper_name with
  | None -> composite_claim_attempt_absent
  | Some call ->
    let output =
      match parse_tool_call_output call with
      | Some (`Assoc _ as output) -> output
      | _ -> `Assoc []
    in
    let claimed_task = json_assoc "claimed_task" output in
    `Assoc
      [ "present", `Bool true
      ; "source", `String "keeper_task_claim_tool_call"
      ; "status", `String (claim_status_of_output output)
      ; "result", Json_util.string_opt_to_json (json_string "result" output)
      ; ( "claimed_task_id",
          match claimed_task with
          | Some task -> Json_util.string_opt_to_json (json_string "task_id" task)
          | None -> `Null )
      ; ( "claimed_goal_id",
          match claimed_task with
          | Some task -> Json_util.string_opt_to_json (json_string "goal_id" task)
          | None -> `Null )
      ]
;;

let find_override_field_source field sources =
  match json_member "override_field_sources" sources with
  | `List values ->
    List.find_opt
      (fun value -> json_string "field" value = Some field)
      values
  | _ -> None
;;

let composite_config_drift_json ~config ~keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Ok (Some meta) ->
    let sources = Keeper_status_bridge.source_provenance_json config meta in
    let override_fields = Json_util.get_string_list sources "override_fields" in
    let runtime_detail = find_override_field_source "model.runtime_id" sources in
    let default_runtime_id, live_runtime_id =
      match runtime_detail with
      | Some detail ->
        Json_util.get_string detail "default_value",
        Json_util.get_string detail "live_value"
      | None -> None, None
    in
    let runtime_override = Option.is_some runtime_detail in
    `Assoc
      [ "present", `Bool true
      ; "status", `String (if runtime_override then "drift" else "ok")
      ; "runtime_override", `Bool runtime_override
      ; "override_fields", Json_util.json_string_list override_fields
      ; "default_runtime_id", Json_util.string_opt_to_json default_runtime_id
      ; "live_runtime_id", Json_util.string_opt_to_json live_runtime_id
      ; "active_config_root", Json_util.string_opt_to_json (json_string "active_config_root" sources)
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

let composite_execution_receipt_json ~(config : Workspace.config) ~claim_window ~keeper_name =
  let claim_attempt = composite_claim_attempt_json ~claim_window ~keeper_name in
  let config_drift = composite_config_drift_json ~config ~keeper_name in
  match Keeper_execution_receipt.latest_json config keeper_name with
  | None ->
    `Assoc
      [ "latest_receipt_present", `Bool false
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
      ; "claim_attempt", claim_attempt
      ; "config_drift", config_drift
      ]
  | Some receipt ->
    let action_radius = json_member "action_radius" receipt in
    `Assoc
      [ "latest_receipt_present", `Bool true
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
      ; "claim_attempt", claim_attempt
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
    [ "preflight_config_error" ]
;;

let composite_execution_claim_no_eligible execution =
  match json_member "claim_attempt" execution with
  | `Assoc _ as claim_attempt ->
    string_opt_is_any (json_string "status" claim_attempt) [ "no_eligible" ]
  | _ -> false
;;

let composite_execution_config_drift execution =
  match json_member "config_drift" execution with
  | `Assoc _ as config_drift ->
    Option.value ~default:false (json_bool "runtime_override" config_drift)
  | _ -> false
;;

let keeper_activation_readiness_json = Server_dashboard_fleet_readiness.keeper_activation_readiness_json

let composite_execution_blocked execution =
  composite_execution_claim_no_eligible execution
  || string_opt_is_any (json_string "operator_disposition" execution) [ "pause_human" ]
  || (match json_string "terminal_reason_code" execution with
      | Some terminal ->
        not (String.equal terminal "")
        && not
             (Keeper_turn_disposition.is_success
                (Keeper_turn_disposition.of_wire terminal))
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

type composite_runtime_attention =
  { cra_is_live : bool
  ; cra_fiber_stop_requested : bool
  ; cra_stale_long_enough : bool
  ; cra_idle_attention : bool
  ; cra_blocked : bool
  ; cra_execution_current : bool
  ; cra_stale_execution_receipt : bool
  ; cra_live_turn_started_at : float option
  ; cra_live_turn_last_progress_at : float option
  ; cra_stale_without_live_turn : bool
  ; cra_needs_attention : bool
  ; cra_reason : string option
  ; cra_state : string
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
    else if composite_execution_claim_no_eligible execution
    then Some "claim_no_eligible"
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
    then "blocked"
    else if fiber_stop_requested
    then "stop_requested"
    else if idle_attention
    then "idle_stale"
    else if stale_without_live_turn
    then "stale"
    else "ok"
  in
  { cra_is_live = is_live
  ; cra_fiber_stop_requested = fiber_stop_requested
  ; cra_stale_long_enough = stale_long_enough
  ; cra_idle_attention = idle_attention
  ; cra_blocked = blocked
  ; cra_execution_current = execution_current
  ; cra_stale_execution_receipt = stale_execution_receipt
  ; cra_live_turn_started_at = composite_live_turn_started_epoch snapshot
  ; cra_live_turn_last_progress_at = composite_live_turn_last_progress_epoch snapshot
  ; cra_stale_without_live_turn = stale_without_live_turn
  ; cra_needs_attention = needs_attention
  ; cra_reason = reason
  ; cra_state = state
  }
;;

let composite_runtime_attention_json attention ~snapshot =
  `Assoc
    [ "state", `String attention.cra_state
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
