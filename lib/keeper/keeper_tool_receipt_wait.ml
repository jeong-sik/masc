open Result.Syntax
module Outbox = Keeper_client_tool_outbox

let refusal ~class_ detail =
  Keeper_tool_execution.failure
    ~class_
    ~effect_disposition:Tool_result.Proven_pre_effect
    (Yojson.Safe.to_string (`Assoc [ "ok", `Bool false; "message", `String detail ]))
;;

let request_id_of_args args =
  let* fields =
    Agent_core.Execution_json.object_fields
      ~context:"keeper_receipt_wait input"
      ~required:[ "request_id" ]
      ~optional:[]
      args
  in
  let* request_id = Agent_core.Execution_json.string_field "request_id" fields in
  if String.equal request_id ""
  then Error "request_id is empty"
  else Ok request_id
;;

(* A request whose run has ended and left no receipt in the outbox had its
   receipt delivered and acknowledged already, or never written. Either way
   nothing is left to wait for. *)
let waitable ~base_path ~keeper_name request_id =
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

let handle ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) ~args =
  match request_id_of_args args with
  | Error detail -> refusal ~class_:Tool_result.Policy_rejection detail
  | Ok request_id ->
    (match
       waitable
         ~base_path:config.Workspace.base_path
         ~keeper_name:meta.Keeper_meta_contract.name
         request_id
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
