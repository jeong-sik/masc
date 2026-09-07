module Http = Http_server_eio
module Reconciliation = Keeper_shutdown_reconciliation
module Store = Keeper_shutdown_store
module Operation = Keeper_shutdown_types

let ( let* ) = Result.bind
let permission = Masc_domain.CanAdmin
let request_schema = "masc.keeper_shutdown.absence_acknowledgement.request.v1"
let prefix = "/api/v1/keepers/"

type target = { keeper_name : string; operation_id : string }

let route path =
  if not (String.starts_with ~prefix path) then None else
    match String.sub path (String.length prefix) (String.length path - String.length prefix)
          |> String.split_on_char '/' with
    | [ keeper_name; "shutdown-operations"; operation_id; "absence-acknowledgement" ]
      when keeper_name <> "" && operation_id <> "" -> Some { keeper_name; operation_id }
    | _ -> None
;;

let target_identity target =
  if not (Keeper_config.validate_name target.keeper_name)
  then Error (Reconciliation.Invalid_request "invalid keeper name")
  else Operation.Operation_id.of_string target.operation_id
    |> Result.map_error (fun detail -> Reconciliation.Invalid_request detail)
;;

type request = { expected_revision : int; expected_backlog_version : int; reason : string }

let parse body =
  let invalid detail = Error (Reconciliation.Invalid_request detail) in
  let* fields = match Yojson.Safe.from_string body with
    | `Assoc fields -> Ok fields
    | _ -> invalid "request must be a JSON object"
    | exception Yojson.Json_error detail -> invalid detail in
  let expected = [ "schema"; "expected_revision"; "expected_backlog_version"; "reason" ] in
  if List.sort String.compare (List.map fst fields) <> List.sort String.compare expected
  then invalid "request requires exactly schema, expected_revision, expected_backlog_version and reason"
  else
    let* () = if List.assoc "schema" fields = `String request_schema then Ok ()
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

let handle_get state request reqd target =
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

let handle_post state ~actor request reqd target body =
  let result =
    let* operation_id = target_identity target in
    let* parsed = parse body in
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
