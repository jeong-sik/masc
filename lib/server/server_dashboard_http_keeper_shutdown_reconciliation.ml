module Http = Http_server_eio
module Reconciliation = Keeper_shutdown_reconciliation
module Store = Keeper_shutdown_store
module Operation = Keeper_shutdown_types
module Retry = Keeper_shutdown_task_settlement_retry

open Result.Syntax
let permission = Masc_domain.CanAdmin
let request_schema = "masc.keeper_shutdown.absence_acknowledgement.request.v1"
let retry_request_schema = "masc.keeper_shutdown.task_settlement_retry.request.v1"
let prefix = Server_dashboard_http_keeper_api_types.keeper_api_prefix

type action = Absence_acknowledgement | Task_settlement_retry
type target = { keeper_name : string; operation_id : string; action : action }

let route path =
  if not (String.starts_with ~prefix path) then None else
    match String.sub path (String.length prefix) (String.length path - String.length prefix)
          |> String.split_on_char '/' with
    | [ keeper_name; "shutdown-operations"; operation_id; "absence-acknowledgement" ]
      when keeper_name <> "" && operation_id <> "" -> Some { keeper_name; operation_id; action = Absence_acknowledgement }
    | [ keeper_name; "shutdown-operations"; operation_id; "task-settlement-retry" ]
      when keeper_name <> "" && operation_id <> "" -> Some { keeper_name; operation_id; action = Task_settlement_retry }
    | _ -> None
;;

let target_identity target =
  if not (Keeper_config.validate_name target.keeper_name)
  then Error (Reconciliation.Invalid_request "invalid keeper name")
  else Operation.Operation_id.of_string target.operation_id
    |> Result.map_error (fun detail -> Reconciliation.Invalid_request detail)
;;

type request = { expected_revision : int; expected_backlog_version : int; reason : string }

let parse ~schema body =
  let invalid detail = Error (Reconciliation.Invalid_request detail) in
  let* fields = match Yojson.Safe.from_string body with
    | `Assoc fields -> Ok fields
    | _ -> invalid "request must be a JSON object"
    | exception Yojson.Json_error detail -> invalid detail in
  let expected = [ "schema"; "expected_revision"; "expected_backlog_version"; "reason" ] in
  if List.sort String.compare (List.map fst fields) <> List.sort String.compare expected
  then invalid "request requires exactly schema, expected_revision, expected_backlog_version and reason"
  else
    let* () = if List.assoc "schema" fields = `String schema then Ok ()
      else invalid "unsupported request schema" in
    let nonnegative field = match List.assoc field fields with
      | `Int value when value >= 0 -> Ok value
      | _ -> invalid (field ^ " must be a non-negative integer") in
    let* expected_revision = nonnegative "expected_revision" in
    let* expected_backlog_version = nonnegative "expected_backlog_version" in
    let* reason = match List.assoc "reason" fields with
      | `String reason when String.trim reason <> "" -> Ok (String.trim reason)
      | _ -> invalid "reason must be a non-empty string" in
    Ok { expected_revision; expected_backlog_version; reason }
;;

let status_of_error = function
  | Reconciliation.Invalid_request _ -> `Bad_request
  | Store_error (Store.Not_found _) -> `Not_found
  | Store_error (Io_error _ | Decode_error _)
  | Backlog_unavailable _ | Owner_unavailable _ | Path_unreadable _
  | Chat_operations_unavailable _ -> `Service_unavailable
  | Store_error (Already_exists _ | Invalid_operation _ | Identity_mismatch _
      | Revision_conflict _ | Supersession_phase_mismatch _
      | Supersession_intent_mismatch _ | Invalid_supersession_actor _)
  | Ineligible_operation | Outstanding_recorded_tasks _ | Outstanding_tasks _
  | Outstanding_chat_operations _ | Outstanding_semantic_executions _ | Backlog_revision_conflict _ | Owner_present
  | Registry_lane_present | Path_present _ | Corrupt_sibling _ | Unfinished_sibling _
  | Admission_owned_by_other _ -> `Conflict
;;

let respond request reqd ?(status = `OK) json =
  Http.Response.json_value ~status ~request
    ~extra_headers:[ "cache-control", "no-store" ] json reqd
;;

let respond_error request reqd error =
  respond request reqd ~status:(status_of_error error)
    (`Assoc [ "ok", `Bool false; "error", `String (Reconciliation.error_to_string error) ])
;;

let handle_absence_get state request reqd target =
  let config = Mcp_server.workspace_config state in
  let preview =
    let* operation_id = target_identity target in
    (* This is an observation for the operator, not an eligibility decision or
       reservation. Commit repeats every guard and checks both revisions. *)
    Workspace_utils_ops.with_file_lock_r config (Workspace_backlog.backlog_lock_path config)
      (fun () ->
        let* operation = Store.load ~config ~keeper_name:target.keeper_name operation_id
          |> Result.map_error (fun error -> Reconciliation.Store_error error) in
        let* backlog = Workspace_backlog.read_backlog_r config
          |> Result.map_error (fun detail -> Reconciliation.Backlog_unavailable detail) in
        Ok (`Assoc
          [ "schema", `String "masc.keeper_shutdown.absence_acknowledgement.preview.v1"
          ; "ok", `Bool true
          ; "operation", Store.to_json operation
          ; "expected_revision", `Int operation.revision
          ; "expected_backlog_version", `Int backlog.version
          ; "eligibility_checked", `Bool false
          ]))
    |> Result.map_error (fun error ->
      Reconciliation.Backlog_unavailable (Masc_domain.masc_error_to_string error))
    |> Result.join
  in
  match preview with
  | Ok json -> respond request reqd json
  | Error error -> respond_error request reqd error
;;

let handle_absence_post state ~actor request reqd target body =
  let result =
    let* operation_id = target_identity target in
    let* parsed = parse ~schema:request_schema body in
    Reconciliation.acknowledge_absent_owner
      ~config:(Mcp_server.workspace_config state) ~keeper_name:target.keeper_name
      ~operation_id ~expected_revision:parsed.expected_revision
      ~expected_backlog_version:parsed.expected_backlog_version ~actor ~reason:parsed.reason
  in
  match result with
  | Error error -> respond_error request reqd error
  | Ok acknowledgement ->
    let status, operation = match acknowledgement with
      | Store.Absence_acknowledged operation -> "acknowledged", operation
      | Store.Absence_already_acknowledged operation -> "already_acknowledged", operation in
    Log.Keeper.info "keeper absent-owner acknowledgement keeper=%s operation=%s actor=%s status=%s"
      target.keeper_name target.operation_id actor status;
    respond request reqd (`Assoc
      [ "schema", `String "masc.keeper_shutdown.absence_acknowledgement.result.v1"
      ; "ok", `Bool true; "status", `String status; "operation", Store.to_json operation ])
;;

let retry_status_of_error = function
  | Retry.Invalid_request _ -> `Bad_request
  | Store_error error -> status_of_error (Reconciliation.Store_error error)
  | Owner_unavailable _ | Owner_observation_failed _ | Owner_stopping
  | Owner_metadata_absent | Backlog_unavailable _ -> `Service_unavailable
  | Ineligible_operation | Owner_trace_changed | Owner_turn_present | Registry_lane_present
  | Lifecycle_reserved _ | Admission_mismatch | Backlog_revision_conflict _
  | Corrupt_sibling _ | Conflicting_sibling _ | Unordered_sibling _
  | New_owned_tasks _ | Recorded_task_changed _ -> `Conflict
;;

let respond_retry_error request reqd error =
  respond request reqd ~status:(retry_status_of_error error)
    (`Assoc [ "ok", `Bool false; "error", `String (Retry.error_to_string error) ])
;;

let handle_retry_get state request reqd target =
  let result =
    let* operation_id = target_identity target
      |> Result.map_error (fun error -> Retry.Invalid_request (Reconciliation.error_to_string error)) in
    let config = Mcp_server.workspace_config state in
    let eligibility = Retry.preview ~config ~keeper_name:target.keeper_name ~operation_id in
    (* Reading the original operation remains possible after preparation,
       finalization or owner removal. Eligibility never gates observation. *)
    let* operation = Store.load ~config ~keeper_name:target.keeper_name operation_id
      |> Result.map_error (fun error -> Retry.Store_error error) in
    Ok (operation, eligibility) in
  match result with
  | Error (Retry.Store_error error) ->
      let status = match error with
        | Store.Not_found _ -> `Not_found
        | Already_exists _ | Io_error _ | Decode_error _ | Invalid_operation _
        | Identity_mismatch _ | Revision_conflict _ | Supersession_phase_mismatch _
        | Supersession_intent_mismatch _ | Invalid_supersession_actor _ -> `Service_unavailable in
      respond request reqd ~status (`Assoc
        [ "ok", `Bool false; "error", `String (Store.error_to_string error) ])
  | Error error -> respond_retry_error request reqd error
  | Ok (operation, eligibility) ->
      let eligible, backlog_version, receipted_ids, observation = match eligibility with
        | Ok preview when preview.operation.revision = operation.revision ->
            true, Some preview.backlog_version, preview.receipted_task_ids, `Null
        | Ok _ -> false, None, [], `String "operation changed during eligibility observation"
        | Error error -> false, None, [], `String (Retry.error_to_string error) in
      respond request reqd (`Assoc
        [ "schema", `String "masc.keeper_shutdown.task_settlement_retry.preview.v1"
        ; "ok", `Bool true; "operation", Store.to_json operation
        ; "expected_revision", `Int operation.revision
        ; "expected_backlog_version", (match backlog_version with None -> `Null | Some version -> `Int version)
        ; "receipted_task_ids", `List (List.map (fun id -> `String (Keeper_id.Task_id.to_string id)) receipted_ids)
        ; "eligible", `Bool eligible; "eligibility_observation", observation
        ; "reservation_created", `Bool false ])
;;

let handle_retry_post state ~actor request reqd target body =
  let config = Mcp_server.workspace_config state in
  let result =
    let* operation_id = target_identity target
      |> Result.map_error (fun error -> Retry.Invalid_request (Reconciliation.error_to_string error)) in
    let* parsed = parse ~schema:retry_request_schema body
      |> Result.map_error (fun error -> Retry.Invalid_request (Reconciliation.error_to_string error)) in
    let prepared = Retry.prepare ~config ~keeper_name:target.keeper_name ~operation_id
      ~expected_revision:parsed.expected_revision ~expected_backlog_version:parsed.expected_backlog_version in
    let audit ~outcome extra =
      match Audit_log.log_action config ~agent_id:actor
        ~action:(Audit_log.Custom "keeper_shutdown_task_settlement_retry") ~outcome
        ~details:(`Assoc ([ "keeper_name", `String target.keeper_name
          ; "operation_id", `String target.operation_id; "reason", `String parsed.reason
          ; "expected_revision", `Int parsed.expected_revision
          ; "expected_backlog_version", `Int parsed.expected_backlog_version ] @ extra)) () with
      | () -> `Assoc [ "state", `String "recorded" ]
      | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
      | exception exn -> `Assoc [ "state", `String "unavailable"
          ; "exception", `String (Printexc.exn_slot_name exn) ] in
    match prepared with
    | Error error -> ignore (audit ~outcome:(Audit_log.Failure (Retry.error_to_string error)) []); Error error
    | Ok operation ->
        (* No filesystem/lifecycle guard is held across worker scheduling. The
           durable CAS remains applied even if the process cannot fork now. *)
        let scheduled, scheduling_json = match Keeper_shutdown_runtime.redrive_finalization ~config
          ~keeper_name:target.keeper_name ~operation_id with
          | Ok Keeper_shutdown_runtime.Redrive_started -> true, `String "started"
          | Ok Redrive_already_active -> true, `String "already_active"
          | Ok (Redrive_not_in_process phase) -> false,
              `Assoc [ "state", `String "not_in_process"; "phase", `String (Operation.phase_to_string phase) ]
          | Error error -> false,
              `Assoc [ "state", `String "unavailable"; "detail", `String (Keeper_shutdown_runtime.redrive_error_to_string error) ]
          | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
          | exception exn -> false, `Assoc [ "state", `String "unavailable"
              ; "exception", `String (Printexc.exn_slot_name exn) ] in
        let audit = audit ~outcome:Audit_log.Success [ "prepared_revision", `Int operation.revision
          ; "scheduled", `Bool scheduled ] in
        Ok (operation, scheduled, scheduling_json, audit)
  in
  match result with
  | Error error -> respond_retry_error request reqd error
  | Ok (operation, scheduled, scheduling, audit) ->
      respond request reqd ~status:(if scheduled then `Accepted else `OK) (`Assoc
        [ "schema", `String "masc.keeper_shutdown.task_settlement_retry.result.v1"
        ; "ok", `Bool true; "applied", `Bool true; "scheduled", `Bool scheduled
        ; "completed", `Bool false; "scheduling", scheduling; "audit", audit
        ; "operation", Store.to_json operation ])
;;

let handle_get state request reqd target = match target.action with
  | Absence_acknowledgement -> handle_absence_get state request reqd target
  | Task_settlement_retry -> handle_retry_get state request reqd target
;;

let handle_post state ~actor request reqd target body = match target.action with
  | Absence_acknowledgement -> handle_absence_post state ~actor request reqd target body
  | Task_settlement_retry -> handle_retry_post state ~actor request reqd target body
;;
