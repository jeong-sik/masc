type capability = Invoke_turn

type target = Keeper of Keeper_id.Keeper_name.t

type request =
  { target : target
  ; capability : capability
  ; prompt : string
  }

type run_ref =
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

type result_contract =
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
  | Invalid_entry_projection

let ( let* ) = Result.bind

let request ~keeper_name ~prompt =
  let* keeper_name =
    Keeper_id.Keeper_name.of_string keeper_name
    |> Result.map_error (fun reason -> Invalid_target reason)
  in
  if String.equal prompt ""
  then Error Empty_prompt
  else Ok { target = Keeper keeper_name; capability = Invoke_turn; prompt }
;;

let request_error_to_string = function
  | Invalid_target reason -> reason
  | Empty_prompt -> "message is required"
  | Invalid_entry_projection -> "Keeper invocation entry projection is not an object"
;;

let target_name (request : request) =
  match request.target with
  | Keeper name -> Keeper_id.Keeper_name.to_string name
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

let result_contract entry =
  match entry.Keeper_msg_async.status with
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

let capability_to_string = function
  | Invoke_turn -> "invoke_turn"
;;

let target_to_json = function
  | Keeper name ->
    `Assoc
      [ "kind", `String "keeper"
      ; "name", `String (Keeper_id.Keeper_name.to_string name)
      ]
;;

let run_ref_to_json reference =
  `Assoc
    [ "run_id", `String reference.run_id
    ; "target", target_to_json reference.target
    ; "capability", `String (capability_to_string reference.capability)
    ]
;;

let result_contract_to_string = function
  | Awaiting_execution -> "awaiting_execution"
  | Publication_uncertain -> "publication_uncertain"
  | Running -> "running"
  | Yielded -> "yielded"
  | Cancellation_requested -> "cancellation_requested"
  | Cancelled -> "cancelled"
  | Completed -> "completed"
  | Failed -> "failed"
;;

let submission_to_json (request : request) outcome =
  let common reference status result_contract =
    [ "request_id", `String outcome.Keeper_msg_async.request_id
    ; "keeper_name", `String (target_name request)
    ; "status", `String status
    ; "run_ref", run_ref_to_json reference
    ; "result_contract", `String (result_contract_to_string result_contract)
    ]
  in
  match submission_receipt request outcome with
  | Durable_run reference ->
    `Assoc
      (common reference "queued" Awaiting_execution
       @ [ ( "message"
           , `String
               "Keeper turn accepted. The caller lane may continue; query masc_keeper_msg_result with run_ref.run_id." )
         ])
  | Reconciliation_required { run_ref = reference; reason } ->
    `Assoc
      (common reference "reconciliation_required" Publication_uncertain
       @ [ "reason", `String reason
         ; ( "operator_instruction"
           , `String
               "Request publication is uncertain. Query masc_keeper_msg_result with this exact run_ref.run_id; do not resubmit." )
         ])
;;

let entry_to_json entry =
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
  match Keeper_msg_async.entry_to_json entry with
  | `Assoc fields ->
    Ok
      (`Assoc
         (fields
          @ [ "run_ref", run_ref_to_json reference
            ; "result_contract", `String (result_contract_to_string contract)
            ]))
  | _ -> Error Invalid_entry_projection
;;
