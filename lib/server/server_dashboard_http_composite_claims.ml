(** Server_dashboard_http_composite — Composite fleet snapshot,
    runtime attention, and recommended-actions JSON builders.

    Extracted from server_dashboard_http.ml during godfile decomposition.
    Depends on Server_dashboard_http_json_utils, Server_dashboard_compact_receipt_json,
    Server_dashboard_fleet_readiness, and various Keeper modules. *)

open Masc_domain
open Server_utils

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
module Completion_contract_result = Keeper_completion_contract_result_label

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

let composite_claim_scope_absent =
  `Assoc
    [ "present", `Bool false
    ; "source", `String "keeper_task_claim_tool_call"
    ; "status", `String "not_observed"
    ; "result", `Null
    ; "mode", `Null
    ; "scoped", `Null
    ; "active_goal_ids", `List []
    ; "effective_goal_ids", `List []
    ; "excluded_count", `Null
    ; "claimed_task_id", `Null
    ; "claimed_goal_id", `Null
    ]
;;

let composite_claim_scope_json ~keeper_name =
  let entries = Keeper_tool_call_log.read_recent ~keeper_name ~n:100 () in
  match
    entries
    |> List.find_opt (fun json ->
      String.equal (Option.value ~default:"" (json_string "tool" json))
        "keeper_task_claim")
  with
  | None -> composite_claim_scope_absent
  | Some call ->
    let output =
      match parse_tool_call_output call with
      | Some (`Assoc _ as output) -> output
      | _ -> `Assoc []
    in
    let claim_scope =
      match json_assoc "claim_scope" output with
      | Some value -> value
      | None -> `Assoc []
    in
    let claimed_task = json_assoc "claimed_task" output in
    `Assoc
      [ "present", `Bool true
      ; "source", `String "keeper_task_claim_tool_call"
      ; "status", `String (claim_status_of_output output)
      ; "result", Json_util.string_opt_to_json (json_string "result" output)
      ; "mode", Json_util.string_opt_to_json (json_string "mode" claim_scope)
      ; ( "scoped",
          match json_bool "scoped" claim_scope with
          | Some value -> `Bool value
          | None -> `Null )
      ; ( "active_goal_ids",
          Json_util.json_string_list
            (Json_util.get_string_list claim_scope "active_goal_ids") )
      ; ( "effective_goal_ids",
          Json_util.json_string_list
            (Json_util.get_string_list claim_scope "effective_goal_ids") )
      ; ( "excluded_count",
          Json_util.int_opt_to_json (json_int "excluded_count" claim_scope) )
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

let composite_execution_receipt_json ~(config : Workspace.config) ~keeper_name =
  let claim_scope = composite_claim_scope_json ~keeper_name in
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
      ; "claim_scope", claim_scope
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
      ; "claim_scope", claim_scope
      ; "config_drift", config_drift
      ]
;;

let lower_string_opt =
  Option.map (fun value -> String.lowercase_ascii (String.trim value))
;;

let completion_contract_result_of_execution execution =
  match json_string "completion_contract_result" execution with
  | Some raw -> Completion_contract_result.of_string raw
  | None -> None
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

let string_opt_has_prefix value ~prefix =
  match lower_string_opt value with
  | Some value -> string_has_prefix ~prefix value
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
  let compaction = json_member "compaction" snapshot in
  let breaker_state =
    match json_member "circuit_breaker" snapshot with
    | `Assoc _ as breaker -> json_string "state" breaker
    | _ -> Some "clean"
  in
  json_string_eq "turn_phase" snapshot "idle"
  && json_string_eq "stage" decision "undecided"
  && json_string_eq "state" runtime "idle"
  && json_string_eq "stage" compaction "accumulating"
  && Option.value ~default:"clean" breaker_state = "clean"
;;

let composite_execution_config_blocked execution =
  string_opt_is_any
    (json_string "operator_disposition_reason" execution)
    [ "preflight_config_error" ]
;;

let composite_execution_saturated execution =
  string_opt_is_any (json_string "terminal_reason_code" execution) [ "ollama_saturated" ]
  || string_opt_is_any
       (json_string "operator_disposition_reason" execution)
       [ "ollama_saturated" ]
;;

let composite_execution_claim_no_eligible execution =
  match json_member "claim_scope" execution with
  | `Assoc _ as claim_scope ->
    string_opt_is_any (json_string "status" claim_scope) [ "no_eligible" ]
  | _ -> false
;;

let composite_execution_contract_blocker_reason execution =
  let recoverable_disposition =
    string_opt_is_any
      (json_string "operator_disposition" execution)
      [ "pause_human"; "pass_next_model"; "fail_open_next_runtime" ]
  in
  if not recoverable_disposition
  then None
  else
    match completion_contract_result_of_execution execution with
    | Some
        ( Completion_contract_result.Surface_mismatch
        | Completion_contract_result.No_capable_provider as result ) ->
      Some
        ("completion_contract_result:" ^ Completion_contract_result.to_string result)
    | _ -> None
;;

let composite_execution_contract_blocked execution =
  match composite_execution_contract_blocker_reason execution with
  | Some _ -> true
  | None -> false
;;

let composite_execution_config_drift execution =
  match json_member "config_drift" execution with
  | `Assoc _ as config_drift ->
    Option.value ~default:false (json_bool "runtime_override" config_drift)
  | _ -> false
;;

let keeper_activation_readiness_json = Server_dashboard_fleet_readiness.keeper_activation_readiness_json

let composite_execution_passive_only_without_work_scope execution =
  match completion_contract_result_of_execution execution with
  | Some Completion_contract_result.Passive_only ->
    Option.is_none (json_string "current_task_id" execution)
    && Json_util.json_string_list_member "goal_ids" execution = []
  | Some _ | None -> false
;;

let composite_execution_completion_unsatisfied_reason execution =
  match completion_contract_result_of_execution execution with
  | Some Completion_contract_result.Passive_only
    when composite_execution_passive_only_without_work_scope execution ->
    None
  | Some
      ( Completion_contract_result.Violated
      | Completion_contract_result.Claim_only_after_owned_task
      | Completion_contract_result.Needs_execution_progress
      | Completion_contract_result.Passive_only as result ) ->
    Some ("completion_contract_result:" ^ Completion_contract_result.to_string result)
  | Some _
  | None -> None
;;

let composite_execution_budget_unsatisfied_reason execution =
  match completion_contract_result_of_execution execution with
  | Some Completion_contract_result.Passive_only
    when composite_execution_passive_only_without_work_scope execution ->
    None
  | Some
      (* TEL-OK: pure dashboard classifier; maps typed receipt labels to a
         display reason without performing an action. *)
      ( Completion_contract_result.Unknown
      | Completion_contract_result.Not_dispatched (* TEL-OK: pure classifier. *)
      | Completion_contract_result.Violated
      | Completion_contract_result.Surface_mismatch
      | Completion_contract_result.No_capable_provider
      | Completion_contract_result.Claim_only_after_owned_task
      | Completion_contract_result.Needs_execution_progress
      | Completion_contract_result.Passive_only as result ) ->
    Some ("completion_contract_result:" ^ Completion_contract_result.to_string result)
  | Some _
  | None -> None
;;

(* Typed budget-exhausted classification.

   The dashboard composite reads the wire [terminal_reason_code] field
   from the typed execution schema. Rather than scanning substrings
   (anti-pattern #2), we route the wire string through the typed
   [Keeper_turn_disposition.of_wire] parser and match on the closed sum.
   An unrecognised string falls through [Unknown _] and yields [false];
   no permissive default, no silent accept. *)
let execution_turn_budget_disposition execution =
  Option.bind (json_string "terminal_reason_code" execution) (fun raw ->
    let trimmed = String.trim raw in
    if String.length trimmed = 0
    then None
    else Some (Keeper_turn_disposition.of_wire (String.lowercase_ascii trimmed)))
;;

let execution_turn_budget_disposition_of_reason reason =
  match reason with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if String.length trimmed = 0
    then None
    else Some (Keeper_turn_disposition.of_wire (String.lowercase_ascii trimmed))
;;

let composite_execution_turn_budget_exhausted execution =
  match json_string "terminal_reason_code" execution with
  | Some raw -> Keeper_turn_disposition.is_turn_budget_exhausted_wire raw
  | None -> false
;;

let composite_execution_budget_exhausted_pass execution =
  string_opt_is_any (json_string "operator_disposition" execution) [ "pass" ]
  && composite_execution_turn_budget_exhausted execution
  && Option.is_none (composite_execution_budget_unsatisfied_reason execution)
  &&
  match execution_turn_budget_disposition_of_reason
          (lower_string_opt (json_string "operator_disposition_reason" execution)) with
  | None -> true
  | Some Keeper_turn_disposition.Success -> true
  | Some (Keeper_turn_disposition.Turn_budget_exhausted _) -> true
  | Some Keeper_turn_disposition.Unknown _ -> true
  | Some _ -> false
;;

let composite_execution_blocked execution =
  composite_execution_claim_no_eligible execution
  || composite_execution_contract_blocked execution
  || Option.is_some (composite_execution_completion_unsatisfied_reason execution)
  || string_opt_is_any (json_string "operator_disposition" execution) [ "pause_human" ]
  || (match lower_string_opt (json_string "terminal_reason_code" execution) with
      | Some terminal ->
        terminal <> ""
        && terminal <> "completed"
        && not (composite_execution_budget_exhausted_pass execution)
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
    then Some "claim_scope_no_eligible"
    else match composite_execution_contract_blocker_reason execution with
    | Some _ as reason -> reason
    | None -> (
      match composite_execution_completion_unsatisfied_reason execution with
      | Some _ as reason -> reason
      | None when not blocked -> None
      | None ->
        (match
           ( composite_execution_turn_budget_exhausted execution,
             composite_execution_budget_unsatisfied_reason execution )
         with
         | true, Some reason -> Some reason
         | _ ->
           (match json_string "operator_disposition_reason" execution with
            | Some value -> String_util.trim_to_option value
            | _ ->
              (match json_string "terminal_reason_code" execution with
               | Some value -> String_util.trim_to_option value
               | _ when needs_attention && composite_execution_config_drift execution ->
                 Some "keeper_runtime_override_drift"
               | _ when blocked -> Some "runtime_blocked"
               | _ -> None))))
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
