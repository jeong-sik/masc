type capability = Keeper_invocation_types.capability = Invoke_turn
type target = Keeper_invocation_types.target = Keeper of Keeper_id.Keeper_name.t

type request =
  { target : target
  ; capability : capability
  ; prompt : string
  }

type run_ref = Keeper_invocation_types.run_ref =
  { run_id : string
  ; target : target
  ; capability : capability
  }

type submission_receipt =
  | Durable_run of run_ref
  | Reconciliation_required of
      { run_ref : run_ref
      ; reason : string
      }

type result_contract = Keeper_invocation_types.result_contract =
  | Awaiting_execution
  | Publication_uncertain
  | Running
  | Yielded
  | Cancellation_requested
  | Cancelled
  | Completed
  | Failed

type request_error =
  | Invalid_target of string
  | Empty_prompt
  | Invalid_wire_value of
      { field : string
      ; expected : string
      }
  | Run_ref_mismatch

let ( let* ) = Result.bind

let invalid_wire_value ~field ~expected =
  Error (Invalid_wire_value { field; expected })
;;

let object_fields ~field = function
  | `Assoc fields -> Ok fields
  | _ -> invalid_wire_value ~field ~expected:"object"
;;

let exact_fields ~field ~allowed fields =
  let keys = List.map fst fields in
  if List.length keys <> List.length (List.sort_uniq String.compare keys)
  then invalid_wire_value ~field ~expected:"object with unique fields"
  else
    match List.find_opt (fun key -> not (List.mem key allowed)) keys with
    | None -> Ok ()
    | Some key ->
      invalid_wire_value
        ~field:(field ^ "." ^ key)
        ~expected:"no undeclared field"
;;

let required_field ~field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> invalid_wire_value ~field:(field ^ "." ^ name) ~expected:"required field"
;;

let string_value ~field = function
  | `String value -> Ok value
  | _ -> invalid_wire_value ~field ~expected:"string"
;;

let target_of_json json =
  let* fields = object_fields ~field:"target" json in
  let* () = exact_fields ~field:"target" ~allowed:[ "kind"; "name" ] fields in
  let* kind = required_field ~field:"target" "kind" fields in
  let* kind = string_value ~field:"target.kind" kind in
  let* name = required_field ~field:"target" "name" fields in
  let* name = string_value ~field:"target.name" name in
  if not (String.equal kind "keeper")
  then invalid_wire_value ~field:"target.kind" ~expected:"keeper"
  else
    Keeper_id.Keeper_name.of_string name
    |> Result.map (fun name -> Keeper name)
    |> Result.map_error (fun reason -> Invalid_target reason)
;;

let capability_of_json ~field = function
  | `String value when String.equal value "invoke_turn" -> Ok Invoke_turn
  | _ -> invalid_wire_value ~field ~expected:"invoke_turn"
;;

let request ~keeper_name ~prompt =
  let* keeper_name =
    Keeper_id.Keeper_name.of_string keeper_name
    |> Result.map_error (fun reason -> Invalid_target reason)
  in
  if String.equal prompt ""
  then Error Empty_prompt
  else Ok { target = Keeper keeper_name; capability = Invoke_turn; prompt }
;;

let request_of_json json =
  let* fields = object_fields ~field:"delegate" json in
  let* () =
    exact_fields
      ~field:"delegate"
      ~allowed:[ "target"; "capability"; "prompt" ]
      fields
  in
  let* target_json = required_field ~field:"delegate" "target" fields in
  let* target = target_of_json target_json in
  let* capability_json = required_field ~field:"delegate" "capability" fields in
  let* capability = capability_of_json ~field:"delegate.capability" capability_json in
  let* prompt_json = required_field ~field:"delegate" "prompt" fields in
  let* prompt = string_value ~field:"delegate.prompt" prompt_json in
  if String.equal prompt "" then Error Empty_prompt else Ok { target; capability; prompt }
;;

let request_error_to_string = function
  | Invalid_target reason -> reason
  | Empty_prompt -> "message is required"
  | Invalid_wire_value { field; expected } ->
    Printf.sprintf "%s must be %s" field expected
  | Run_ref_mismatch -> "run_ref does not identify the stored Keeper invocation"
;;

let target_name_of_target = Keeper_invocation_types.target_name

let target_name (request : request) =
  target_name_of_target request.target
;;

let prompt (request : request) = request.prompt

let submit ~background_sw ~base_path ~caller ~(request : request) ~f () =
  Keeper_msg_async.submit
    ~background_sw
    ~base_path
    ~caller
    ~keeper_name:(target_name request)
    ~f:(f request)
    ()
;;

let run_ref (request : request) run_id =
  { run_id; target = request.target; capability = request.capability }
;;

let submission_receipt (request : request) outcome =
  let reference = run_ref request outcome.Keeper_msg_async.request_id in
  match outcome.acceptance with
  | Keeper_msg_async.Durably_accepted -> Durable_run reference
  | Keeper_msg_async.Reconciliation_required { reason } ->
    Reconciliation_required { run_ref = reference; reason }
;;

let result_contract_of_status = function
  | Keeper_msg_async.Queued -> Awaiting_execution
  | Keeper_msg_async.Running -> Running
  | Keeper_msg_async.Cancelling _ -> Cancellation_requested
  | Keeper_msg_async.Cancelled _ -> Cancelled
  | Keeper_msg_async.Lost _
  | Keeper_msg_async.Persistence_failed _
  | Keeper_msg_async.Done { ok = false; _ } -> Failed
  | Keeper_msg_async.Done { ok = true; data; _ } ->
    (match Keeper_turn_outcome.of_reply_payload data with
     | Keeper_turn_outcome.Continuation_checkpoint -> Yielded
     | Keeper_turn_outcome.Visible_reply
     | Keeper_turn_outcome.No_visible_reply -> Completed)
;;

let result_contract entry = result_contract_of_status entry.Keeper_msg_async.status

let target_to_json = Keeper_invocation_types.target_to_json
let run_ref_to_json = Keeper_invocation_types.run_ref_to_json

let run_ref_of_json json =
  let* fields = object_fields ~field:"run_ref" json in
  let* () =
    exact_fields
      ~field:"run_ref"
      ~allowed:[ "run_id"; "target"; "capability" ]
      fields
  in
  let* run_id_json = required_field ~field:"run_ref" "run_id" fields in
  let* run_id = string_value ~field:"run_ref.run_id" run_id_json in
  let* target_json = required_field ~field:"run_ref" "target" fields in
  let* target = target_of_json target_json in
  let* capability_json = required_field ~field:"run_ref" "capability" fields in
  let* capability = capability_of_json ~field:"run_ref.capability" capability_json in
  if String.equal run_id ""
  then invalid_wire_value ~field:"run_ref.run_id" ~expected:"non-empty string"
  else Ok { run_id; target; capability }
;;

let run_id = Keeper_invocation_types.run_id
let run_ref_target_name = Keeper_invocation_types.run_ref_target_name

let run_ref_matches_entry reference (entry : Keeper_msg_async.entry) =
  String.equal reference.run_id entry.Keeper_msg_async.request_id
  && String.equal
       (target_name_of_target reference.target)
       entry.Keeper_msg_async.keeper_name
;;

let validate_entry reference entry =
  if run_ref_matches_entry reference entry
  then Ok entry
  else Error Run_ref_mismatch
;;

let poll ~base_path ~caller reference =
  let run_id = run_id reference in
  match Keeper_msg_async.poll ~base_path ~caller run_id with
  | Keeper_msg_async.Found entry ->
    validate_entry reference entry |> Result.map (fun entry -> Keeper_msg_async.Found entry)
  | (Keeper_msg_async.Absent
    | Keeper_msg_async.Unreadable _
    | Keeper_msg_async.Rejected _) as result -> Ok result
;;

let cancel ~base_path ~caller reference =
  match poll ~base_path ~caller reference with
  | Error error -> Error error
  | Ok (Keeper_msg_async.Found _) ->
    Ok (Keeper_msg_async.cancel ~base_path ~caller (run_id reference))
  | Ok Keeper_msg_async.Absent -> Ok Keeper_msg_async.Cancel_not_found
  | Ok (Keeper_msg_async.Unreadable reason) ->
    Ok (Keeper_msg_async.Cancel_unreadable reason)
  | Ok (Keeper_msg_async.Rejected rejection) ->
    Ok (Keeper_msg_async.Cancel_rejected rejection)
;;

let result_contract_to_string = Keeper_invocation_types.result_contract_to_string
let result_contract_of_string = Keeper_invocation_types.result_contract_of_string

let delegate_submission_to_json (request : request) outcome =
  let common reference result_contract =
    [ "run_ref", run_ref_to_json reference
    ; "result_contract", `String (result_contract_to_string result_contract)
    ]
  in
  match submission_receipt request outcome with
  | Durable_run reference ->
    `Assoc
      (common reference Awaiting_execution
       @ [ ( "message"
           , `String
               "Keeper turn accepted. The caller lane may continue; query masc_keeper_delegate_status with the exact run_ref." )
         ])
  | Reconciliation_required { run_ref = reference; reason } ->
    `Assoc
      (common reference Publication_uncertain
       @ [ "reason", `String reason
         ; ( "operator_instruction"
           , `String
               "Request publication is uncertain. Query masc_keeper_delegate_status with this exact run_ref; do not resubmit." )
         ])
;;

let delegate_submission_error_to_json request = function
  | Keeper_msg_async.Submit_rejected rejection ->
    Keeper_msg_async.access_rejection_to_json rejection
  | Keeper_msg_async.Submit_invalid_keeper_name { reason } ->
    `Assoc [ "error", `String "invalid_target"; "message", `String reason ]
  | Keeper_msg_async.Initial_persistence_failed { reason } ->
    `Assoc [ "error", `String "invocation_persistence_failed"; "message", `String reason ]
  | Keeper_msg_async.Acceptance_persistence_failed { request_id; reason } ->
    `Assoc
      [ "error", `String "invocation_acceptance_uncertain"
      ; "run_ref", run_ref_to_json (run_ref request request_id)
      ; "result_contract", `String (result_contract_to_string Publication_uncertain)
      ; "message", `String reason
      ]
  | Keeper_msg_async.Background_switch_unavailable { reason } ->
    `Assoc [ "error", `String "background_switch_unavailable"; "message", `String reason ]
  | Keeper_msg_async.Background_fork_failed { request_id; reason } ->
    `Assoc
      [ "error", `String "invocation_background_start_failed"
      ; "run_ref", run_ref_to_json (run_ref request request_id)
      ; "result_contract", `String (result_contract_to_string Failed)
      ; "message", `String reason
      ]
;;

let entry_result = function
  | Keeper_msg_async.Queued | Keeper_msg_async.Running -> []
  | Keeper_msg_async.Done { body; data; _ } ->
    [ ( "result"
      , match data with
        | Some value -> value
        | None -> `String body )
    ]
  | Keeper_msg_async.Lost { reason } ->
    [ "result", `Assoc [ "error", `String "invocation_lost"; "reason", `String reason ] ]
  | Keeper_msg_async.Cancelled { reason; cancelled_by } ->
    [ ( "result"
      , `Assoc
          [ "reason", `String reason
          ; "cancelled_by", `String cancelled_by
          ] )
    ]
  | Keeper_msg_async.Cancelling { reason; cancelled_by } ->
    [ ( "result"
      , `Assoc
          [ "reason", `String reason
          ; "cancelled_by", `String cancelled_by
          ] )
    ]
  | Keeper_msg_async.Persistence_failed { attempted_status; reason } ->
    [ ( "result"
      , `Assoc
          [ "error", `String "invocation_persistence_failed"
          ; "attempted_status", `String attempted_status
          ; "reason", `String reason
          ] )
    ]
;;

let delegate_entry_to_json (entry : Keeper_msg_async.entry) =
  let contract = result_contract entry in
  let* target_name =
    Keeper_id.Keeper_name.of_string entry.Keeper_msg_async.keeper_name
    |> Result.map_error (fun reason -> Invalid_target reason)
  in
  let reference =
    { run_id = entry.request_id
    ; target = Keeper target_name
    ; capability = Invoke_turn
    }
  in
  let timing =
    match entry.completed_at with
    | Some completed_at -> [ "completed_at", `Float completed_at ]
    | None -> []
  in
  Ok
    (`Assoc
       ([ "run_ref", run_ref_to_json reference
        ; "result_contract", `String (result_contract_to_string contract)
        ; "submitted_at", `Float entry.submitted_at
        ]
        @ timing
        @ entry_result entry.status))
;;

let delegate_cancellation_to_json reference result =
  let common = [ "run_ref", run_ref_to_json reference ] in
  let contract status =
    [ "result_contract", `String (result_contract_to_string status) ]
  in
  let durability = function
    | Keeper_msg_async.Durably_committed -> [ "durability", `String "durable" ]
    | Keeper_msg_async.Published_unconfirmed { reason } ->
      [ "durability", `String "publication_uncertain"; "warning", `String reason ]
  in
  let fields =
    match result with
    | Keeper_msg_async.Cancellation_requested state ->
      contract Cancellation_requested @ durability state
    | Keeper_msg_async.Cancel_not_found -> [ "error", `String "run_not_found" ]
    | Keeper_msg_async.Cancel_unreadable reason ->
      [ "error", `String "invocation_record_unreadable"; "message", `String reason ]
    | Keeper_msg_async.Cancel_rejected rejection ->
      [ "error", `String "invocation_access_rejected"
      ; "reason", Keeper_msg_async.access_rejection_to_json rejection
      ]
    | Keeper_msg_async.Cancel_worker_ownership_unknown status ->
      contract (result_contract_of_status status)
      @ [ "error", `String "invocation_worker_ownership_unknown" ]
    | Keeper_msg_async.Cancel_already_terminal status ->
      contract (result_contract_of_status status)
      @ [ "error", `String "invocation_already_terminal" ]
    | Keeper_msg_async.Cancel_persistence_failed { reason } ->
      [ "error", `String "cancellation_persistence_failed"; "message", `String reason ]
    | Keeper_msg_async.Cancel_worker_signal_failed { durability = state; reason } ->
      contract Cancellation_requested
      @ durability state
      @ [ "error", `String "cancellation_worker_signal_failed"; "message", `String reason ]
    | Keeper_msg_async.Cancel_state_invariant_failed { reason } ->
      [ "error", `String "cancellation_state_invariant_failed"; "message", `String reason ]
  in
  `Assoc (common @ fields)
;;
