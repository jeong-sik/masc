(** The operator recovery surface for restart residuals (design D4,
    task-1665).

    Two closed recovery paths, both explicit operator actions — nothing
    here runs on a timer or a boot pass:

    - [rearm]: clear an install-only restart latch. Boot projects an
      {i Exact_dispatch_uncertain} attempt to the durable
      [Exact_restart_quarantined] latch (and a released-before-dispatch
      proof into [Exact_released_recovery_required]); the only way back to
      a fresh unbound flow is an operator rearm. The queue's
      [reserve_summary_attempt_retry] owns that contract — typed CAS over
      (identity, exact attempt, disposition), rearming summary judgment
      creation only, never re-dispatching an external tool.
    - [ack_uncertain]: acknowledge a consume-only late-approval tail. The
      journal cannot separate "never delivered" from "delivered, outcome
      unwritten", so D2 stops at a warning count; this surface lets the
      operator acknowledge having seen it. An ack is a warning
      acknowledgement, never a re-authorization. *)

module Http = Http_server_eio

let permission = Masc_domain.CanAdmin
let prefix = "/api/v1/keepers/"

let route path =
  if not (String.starts_with ~prefix path)
  then None
  else
    match
      String.sub path (String.length prefix) (String.length path - String.length prefix)
      |> String.split_on_char '/'
    with
    | [ "hitl"; "approvals"; approval_id; "recover" ] when approval_id <> "" ->
      Some approval_id
    | _ -> None
;;

let respond request reqd ?(status = `OK) json =
  Http.Response.json_value
    ~status
    ~request
    ~extra_headers:[ "cache-control", "no-store" ]
    json
    reqd
;;

let respond_error request reqd ~status ~code detail =
  respond
    request
    reqd
    ~status
    (`Assoc
       [ "ok", `Bool false
       ; "code", `String code
       ; "error", `String detail
       ; "approval_id", `Null
       ])
;;

let nonempty_trimmed_string name = function
  | `String value when value <> "" && String.equal value (String.trim value) ->
    Ok value
  | _ -> Error (name ^ " must be a non-empty trimmed string")
;;

type rearm_request =
  { id : string
  ; input_hash : string
  ; sequence : int
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; expected_exact_attempt : Keeper_approval_queue_rules_types.exact_attempt_state
  ; expected_disposition :
      Keeper_approval_queue_rules_types.summary_attempt_disposition
  }

let parse_rearm_fields fields =
  let ( let* ) = Result.bind in
  let required name =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error ("recover request." ^ name ^ " is required")
  in
  let* _action = required "action" in
  let* id = required "id" in
  let* id = nonempty_trimmed_string "recover request.id" id in
  let* input_hash = required "input_hash" in
  let* input_hash =
    match input_hash with
    | `String value when Keeper_approval_queue_rules_types.is_lowercase_sha256 value ->
      Ok value
    | _ -> Error "recover request.input_hash must be a lowercase SHA-256"
  in
  let* sequence = required "sequence" in
  let* sequence =
    match sequence with
    | `Int value when value > 0 -> Ok value
    | _ -> Error "recover request.sequence must be a positive integer"
  in
  let* slot_id = required "slot_id" in
  let* slot_id = nonempty_trimmed_string "recover request.slot_id" slot_id in
  let* call_id = required "call_id" in
  let* call_id = nonempty_trimmed_string "recover request.call_id" call_id in
  let* plan_fingerprint = required "plan_fingerprint" in
  let* plan_fingerprint =
    nonempty_trimmed_string "recover request.plan_fingerprint" plan_fingerprint
  in
  let* request_body_sha256 = required "request_body_sha256" in
  let* request_body_sha256 =
    match request_body_sha256 with
    | `String value when Keeper_approval_queue_rules_types.is_lowercase_sha256 value ->
      Ok value
    | _ ->
      Error "recover request.request_body_sha256 must be a lowercase SHA-256"
  in
  let* exact_attempt_json = required "exact_attempt" in
  let* expected_exact_attempt =
    Keeper_approval_queue_rules_types.exact_attempt_state_of_yojson_with_error
      exact_attempt_json
  in
  let* () =
    match expected_exact_attempt with
    | Keeper_approval_queue_rules_types.Exact_bound
        { status =
            ( Keeper_approval_queue_rules_types.Exact_restart_quarantined
            | Keeper_approval_queue_rules_types.Exact_released_recovery_required )
        ; _
        } ->
      Ok ()
    | _ ->
      Error
        "recover rearm targets restart-latched exact attempts \
         (Exact_restart_quarantined or Exact_released_recovery_required)"
  in
  let* disposition_json = required "summary_attempt_disposition" in
  let* expected_disposition =
    Keeper_approval_queue_rules_types.summary_attempt_disposition_of_yojson_with_error
      disposition_json
  in
  let* () =
    match expected_disposition with
    | Keeper_approval_queue_rules_types.Summary_attempt_in_flight
    | Keeper_approval_queue_rules_types.Summary_attempt_persistence_uncertain ->
      Ok ()
    | _ ->
      Error
        "recover rearm requires summary_attempt_disposition in_flight or \
         persistence_uncertain"
  in
  Ok
    { id
    ; input_hash
    ; sequence
    ; slot_id
    ; call_id
    ; plan_fingerprint
    ; request_body_sha256
    ; expected_exact_attempt
    ; expected_disposition
    }
;;

let parse_ack_fields fields =
  let ( let* ) = Result.bind in
  let required name =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error ("recover request." ^ name ^ " is required")
  in
  let* action = required "action" in
  let* () =
    match action with
    | `String "ack_uncertain" -> Ok ()
    | `String other ->
      Error
        (Printf.sprintf
           "recover request.action must be \"ack_uncertain\", got %s"
           other)
    | _ -> Error "recover request.action must be the string \"ack_uncertain\""
  in
  let* keeper_name = required "keeper_name" in
  let* keeper_name = nonempty_trimmed_string "recover request.keeper_name" keeper_name in
  let* () = if List.sort String.compare (List.map fst fields) =
      ["action";"consume_id";"keeper_name"] then Ok ()
    else Error "ack requires only action, keeper_name and consume_id" in
  let* consume_id = required "consume_id" in
  let* consume_id = match consume_id with
    | `String id when id <> "" -> Ok id
    | _ -> Error "recover request.consume_id must be a nonempty exact ID" in
  Ok (keeper_name, consume_id)
;;

let parse_json body =
  match Yojson.Safe.from_string body with
  | json -> Ok json
  | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
;;

let object_fields what = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names = List.length (List.sort_uniq String.compare names)
    then Ok fields
    else Error (what ^ " contains duplicate fields")
  | json ->
    Error
      (Printf.sprintf
         "%s must be an object, received %s"
         what
         (Json_util.kind_name json))
;;

let rearm_json ~base_path ~requested_by ~approval_id ~input_hash ~sequence
    ~slot_id ~call_id ~plan_fingerprint ~request_body_sha256
    ~expected_exact_attempt ~expected_disposition =
  match
    Keeper_approval_queue.reserve_summary_attempt_retry
      ~base_path
      ~id:approval_id
      ~input_hash
      ~sequence
      ~expected_exact_attempt
      ~expected_disposition
      ~requested_by
  with
  | Ok true ->
    Log.Keeper.info
      ~keeper_name:"server"
      "operator recovered restart-latched approval=%s actor=%s (rearm resumes summary creation, never re-dispatches the tool)"
      approval_id
      requested_by;
    Ok
      (`Assoc
         [ "ok", `Bool true
         ; "approval_id", `String approval_id
         ; "action", `String "rearm"
         ; "rearmed", `Bool true
         ])
  | Ok false ->
    (* The typed precondition did not hold at write time — the row is not
       restart-latched anymore (already rearmed, settled, or terminal). The
       queue's CAS returns changed=false instead of guessing why. *)
    Error
      (`Status_conflict, "approval is not in a restart-latched recovery state")
  | Error
      (Keeper_approval_queue_result.Exact_attempt_rejected
         (Keeper_approval_queue_result.Exact_attempt_not_found _)) ->
    Error (`Not_found, "pending approval not found: " ^ approval_id)
  | Error
      (Keeper_approval_queue_result.Exact_attempt_rejected
         (Keeper_approval_queue_result.Exact_attempt_key_mismatch _)) ->
    Error (`Status_conflict, "approval identity mismatch (row moved)")
  | Error error ->
    Error
      ( `Unavailable
      , Keeper_approval_queue_result.exact_attempt_error_to_string error )
;;

let ack_json ~base_path ~approval_id ~keeper_name ~consume_id =
  let store = Keeper_late_approval.shared () in
  let outcome =
    Keeper_late_approval.ack_uncertain store ?now:None ~base_path
      ~keeper_name ~consume_id ()
  in
  match outcome with
  | Keeper_late_approval.Acked ->
    Ok
      (`Assoc
         [ "ok", `Bool true
         ; "approval_id", `String approval_id
         ; "action", `String "ack_uncertain"
         ; "consume_id", `String consume_id
         ; "acked", `Bool true
         ; ("late_uncertain"
           , `Int
               (Keeper_late_approval.journal_uncertain
                  (Keeper_late_approval.shared ())))
         ])
  | Keeper_late_approval.Not_uncertain ->
    Error
      ( `Status_conflict
      , "no consume-only tail stands for this identity (delivered, acked, \
         or never consumed)" )
  | Keeper_late_approval.Ack_not_journaled ->
    Error (`Unavailable, "ack journal append failed; the count is unchanged")
;;

(** Handle one recover POST. The workspace is the authenticated caller's:
    a dashboard token cannot reach into another workspace's queue because
    both queue mutations and the late-approval ack key their identity on
    [base_path]. *)
let handle_post state ~actor ~approval_id request reqd body =
  let base_path = (Mcp_server.workspace_config state).base_path in  match parse_json body with
  | Error detail ->
    respond_error request reqd ~status:`Bad_request ~code:"invalid_request" detail
  | Ok json -> (
    match object_fields "recover request" json with
    | Error detail ->
      respond_error request reqd ~status:`Bad_request ~code:"invalid_request" detail
    | Ok fields -> (
      match List.assoc_opt "action" fields with
      | Some (`String "rearm") -> (
        match parse_rearm_fields fields with
        | Error detail ->
          respond_error request reqd ~status:`Bad_request ~code:"invalid_request" detail
        | Ok parsed ->
          if not (String.equal parsed.id approval_id)
          then
            respond_error request reqd ~status:`Bad_request
              ~code:"invalid_request"
              "recover request.id must match the path approval id"
          else
            match
              rearm_json
                ~base_path
                ~requested_by:actor
                ~approval_id
                ~input_hash:parsed.input_hash
                ~sequence:parsed.sequence
                ~slot_id:parsed.slot_id
                ~call_id:parsed.call_id
                ~plan_fingerprint:parsed.plan_fingerprint
                ~request_body_sha256:parsed.request_body_sha256
                ~expected_exact_attempt:parsed.expected_exact_attempt
                ~expected_disposition:parsed.expected_disposition
            with
            | Ok json -> respond request reqd json
            | Error (`Status_conflict, detail) ->
              respond_error request reqd ~status:`Conflict ~code:"status_conflict" detail
            | Error (`Not_found, detail) ->
              respond_error request reqd ~status:`Not_found
                ~code:"approval_not_found" detail
            | Error (`Unavailable, detail) ->
              respond_error request reqd ~status:`Service_unavailable
                ~code:"queue_unavailable" detail)
      | Some (`String "ack_uncertain") -> (
        match parse_ack_fields fields with
        | Error detail ->
          respond_error request reqd ~status:`Bad_request ~code:"invalid_request" detail
        | Ok (keeper_name, consume_id) ->
          match ack_json ~base_path ~approval_id ~keeper_name ~consume_id with
          | Ok json -> respond request reqd json
          | Error (`Status_conflict, detail) ->
            respond_error request reqd ~status:`Conflict ~code:"status_conflict" detail
          | Error (`Unavailable, detail) ->
            respond_error request reqd ~status:`Service_unavailable
              ~code:"journal_unavailable" detail)
      | Some action ->
        respond_error request reqd ~status:`Bad_request ~code:"invalid_request"
          (Printf.sprintf
             "recover request.action must be \"rearm\" or \"ack_uncertain\", got %s"
             (Yojson.Safe.to_string action))
      | None ->
        respond_error request reqd ~status:`Bad_request ~code:"invalid_request"
          "recover request.action is required"))

let uncertain_path = "/api/v1/keepers/hitl/late-approval-attempts"
let uncertain_response state =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  match Keeper_late_approval.uncertain_attempts (Keeper_late_approval.shared ()) ~base_path with
  | Error (Keeper_late_approval.Corrupt_journal _ | Journal_unavailable _) ->
      `Service_unavailable, `Assoc ["ok", `Bool false; "code", `String "late_approval_journal_unavailable"]
  | Ok attempts -> `OK, `Assoc ["ok", `Bool true;
      "attempts", `List (List.map (fun (a : Keeper_late_approval.uncertain_attempt) -> `Assoc
        ["consume_id", `String a.consume_id; "keeper_name", `String a.keeper_name;
         "tool_name", `String a.tool_name; "args_fingerprint", `String a.args_fingerprint;
         "consumed_at", `Float a.consumed_at; "outcome", `String "unknown"]) attempts)]
let handle_uncertain_get state request reqd =
  let status, body = uncertain_response state in respond request reqd ~status body
