open Result.Syntax
module Outbox = Keeper_client_tool_outbox

let refusal ~class_ detail =
  Keeper_tool_execution.failure
    ~class_
    ~effect_disposition:Tool_result.Proven_pre_effect
    (Yojson.Safe.to_string (`Assoc [ "ok", `Bool false; "message", `String detail ]))
;;

(* What the model named: the id Execute returned for a background run, or the
   schedule id of a Keeper wake whose delivery is [receipt]. *)
type target =
  | Run of string
  | Schedule of string

let id_of_target = function
  | Run id | Schedule id -> id
;;

(* A field the call may leave out. Absent or null is no id. *)
let optional_id name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    if String.equal value "" then Error (name ^ " is empty") else Ok (Some value)
  | Some _ -> Error ("field " ^ name ^ " must be a string")
;;

let target_of_args args =
  let* fields =
    Agent_core.Execution_json.object_fields
      ~context:"keeper_receipt_wait input"
      ~required:[]
      ~optional:[ "request_id"; "schedule_id" ]
      args
  in
  let* request_id = optional_id "request_id" fields in
  let* schedule_id = optional_id "schedule_id" fields in
  match request_id, schedule_id with
  | Some id, None -> Ok (Run id)
  | None, Some id -> Ok (Schedule id)
  | None, None -> Error "give request_id or schedule_id"
  | Some _, Some _ -> Error "give request_id or schedule_id, not both"
;;

(* A request whose run has ended and left no receipt in the outbox had its
   receipt delivered and acknowledged already, or never written. Either way
   nothing is left to wait for. *)
let waitable_run ~base_path ~keeper_name request_id =
  match
    Keeper_msg_async.load_canonical_request ~base_path ~caller:keeper_name request_id
  with
  | Keeper_msg_async.Absent ->
    Error
      ( Tool_result.Workflow_rejection
      , "No background run of this Keeper has this request_id." )
  | Keeper_msg_async.Unreadable reason ->
    Error
      ( Tool_result.Dependency_unavailable
      , Printf.sprintf "The request record cannot be read: %s" reason )
  | Keeper_msg_async.Rejected _ ->
    Error
      ( Tool_result.Workflow_rejection
      , "No background run of this Keeper has this request_id." )
  | Keeper_msg_async.Found entry ->
    (match Keeper_execute_background.request_arguments entry with
     | None ->
       Error
         ( Tool_result.Workflow_rejection
         , "This request is not a background Execute run." )
     | Some _ ->
       if Keeper_receipt_wait_resolution.request_may_have_worker entry
       then Ok ()
       else (
         match Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt with
         | Error detail ->
           Error
             ( Tool_result.Dependency_unavailable
             , Printf.sprintf "The receipt outbox cannot be read: %s" detail )
         | Ok snapshot ->
           if Outbox.contains_call snapshot ~call_id:request_id
           then Ok ()
           else
             Error
               ( Tool_result.Workflow_rejection
               , "This run has ended and its receipt is no longer waiting." )))
;;

(* A schedule whose wake delivers a receipt and has not ended will write one. An
   ended one has either written it, and it waits in the outbox, or ended
   without, and nothing will arrive. *)
let waitable_schedule ~base_path ~keeper_name schedule_id =
  match Keeper_receipt_wait_source.find_schedule ~base_path ~keeper_name schedule_id with
  | Error detail ->
    Error
      ( Tool_result.Dependency_unavailable
      , Printf.sprintf "The schedule cannot be read: %s" detail )
  | Ok Keeper_receipt_wait_source.No_row ->
    Error
      ( Tool_result.Workflow_rejection
      , "No wake of this Keeper has this schedule_id." )
  | Ok Keeper_receipt_wait_source.Row_delivers_to_queue ->
    Error
      ( Tool_result.Workflow_rejection
      , "This wake delivers a queue message, not a receipt. Create it with delivery \
         receipt." )
  | Ok Keeper_receipt_wait_source.Row_waiting -> Ok ()
  | Ok Keeper_receipt_wait_source.Row_ended ->
    (match Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt with
     | Error detail ->
       Error
         ( Tool_result.Dependency_unavailable
         , Printf.sprintf "The receipt outbox cannot be read: %s" detail )
     | Ok snapshot ->
       if Outbox.contains_call snapshot ~call_id:schedule_id
       then Ok ()
       else
         Error
           ( Tool_result.Workflow_rejection
           , "This wake has ended and its receipt is no longer waiting." ))
;;

let waitable ~base_path ~keeper_name = function
  | Run request_id -> waitable_run ~base_path ~keeper_name request_id
  | Schedule schedule_id ->
    waitable_schedule ~base_path ~keeper_name schedule_id
;;

(* An execution that already waits for the request keeps it. Another
   execution's wait is refused at the end of the turn too, in the transaction
   that records the wait; this read only lets the model hear it now. The
   journal is read outside the Owner, so a wait that starts after this read is
   still caught by that transaction. *)
let not_waited_by_another ~base_path ~keeper_name ~execution_scope request_id =
  match execution_scope with
  | None ->
    Error
      ( Tool_result.Workflow_rejection
      , "This run serves no conversation, so it has no turn to end on a receipt." )
  | Some scope ->
    (match Keeper_receipt_wait_resolution.request_owner ~base_path ~keeper_name ~request_id with
     | Error detail -> Error (Tool_result.Dependency_unavailable, detail)
     | Ok None -> Ok ()
     | Ok (Some owner) ->
       if Keeper_execution_scope_id.equal owner scope
       then Ok ()
       else
         Error
           ( Tool_result.Workflow_rejection
           , "Another conversation of this Keeper already waits for the receipt of this \
              request." ))
;;

let handle
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~execution_scope
      ~args
  =
  match target_of_args args with
  | Error detail -> refusal ~class_:Tool_result.Policy_rejection detail
  | Ok target ->
    let request_id = id_of_target target in
    let base_path = config.Workspace.base_path in
    let keeper_name = meta.Keeper_meta_contract.name in
    (match
       Result.bind (waitable ~base_path ~keeper_name target) (fun () ->
         not_waited_by_another ~base_path ~keeper_name ~execution_scope request_id)
     with
     | Error (class_, detail) -> refusal ~class_ detail
     | Ok () ->
       Keeper_tool_execution.success_data
         (`Assoc
             [ "ok", `Bool true
             ; "status", `String "waiting"
             ; "request_id", `String request_id
             ; ( "message"
               , `String
                   "This turn ends here. A later run of this conversation starts \
                    with the receipt of this request." )
             ])
       |> Keeper_tool_execution.with_receipt_wait_receipt ~request_id)
;;
