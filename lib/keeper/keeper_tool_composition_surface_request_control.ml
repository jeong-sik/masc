module Catalog = Keeper_tool_composition_catalog
open Keeper_tool_composition_projection
open Keeper_tool_composition_surface_schema

let result_from_json ~tool_name ~start_time ~class_ ~ok data =
  if ok
  then Tool_result.make_ok ~tool_name ~start_time ~data ()
  else
    Tool_result.make_err
      ~tool_name
      ~class_
      ~start_time
      ~data
      (Yojson.Safe.to_string data)
;;

type async_submission_error =
  | Submission_result of Tool_result.result
  | Broker_error of Keeper_msg_async.submit_error

let discard_status_binding ~delivery_registry ~invocation =
  match delivery_registry,invocation with
  | Some registry,Some invocation -> Keeper_composition_result_delivery.discard_status registry ~invocation
  | None,Some _ | Some _,None | None,None -> ()
;;

let status_result_for_invocation
      ?delivery_registry
      ?invocation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~request_id
      ()
  =
  let tool_name = Catalog.status_tool_name in
  let start_time = Tool_timing.start () in
  let with_kind = with_tool_kind_field Catalog.status_tool_kind in
  match
    Keeper_msg_async.poll
      ~base_path:config.base_path
      ~caller:meta.name
      request_id
  with
  | Keeper_msg_async.Found entry ->
    let snapshot = Keeper_composition_result_delivery.observe_status
        ~base_path:config.base_path ?invocation entry in
    let result =
      result_from_json
        ~tool_name
        ~start_time
        ~class_:Tool_result.Runtime_failure
        ~ok:true
        (Keeper_composition_result_delivery.status_payload snapshot)
    in
    (match Tool_bridge.attach_artifact_manifest
             ~projection:Tool_output.Inline_with_reference ~base_path:config.base_path result with
     | Ok result ->
       (match delivery_registry,invocation with
        | Some registry,Some invocation ->
          (match Keeper_composition_result_delivery.record_status registry ~snapshot ~invocation ~result with
           | Ok () -> ()
           | Error error -> Log.Keeper.warn
               "Prepared composition status binding failed keeper=%s request_id=%s detail=%s"
               meta.name request_id (Keeper_composition_result_delivery.error_to_string error))
        | None,Some _ | Some _,None | None,None -> ());
       result
     | Error { message; _ } ->
       discard_status_binding ~delivery_registry ~invocation;
       Tool_result.make_err
         ~tool_name
         ~class_:Tool_result.Runtime_failure
         ~start_time
         ("async composition status manifest persistence failed: " ^ message))
  | Keeper_msg_async.Absent ->
    discard_status_binding ~delivery_registry ~invocation;
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Workflow_rejection
      ~ok:false
      (with_kind
         (`Assoc
             [ "error", `String "request_id_not_found"
             ; "request_id", `String request_id
             ]))
  | Keeper_msg_async.Unreadable reason ->
    discard_status_binding ~delivery_registry ~invocation;
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Runtime_failure
      ~ok:false
      (with_kind
         (`Assoc
             [ "error", `String "request_record_unreadable"
             ; "request_id", `String request_id
             ; "reason", `String reason
             ]))
  | Keeper_msg_async.Rejected rejection ->
    discard_status_binding ~delivery_registry ~invocation;
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Policy_rejection
      ~ok:false
      (with_kind
         (`Assoc
             [ "error", `String "request_access_rejected"
             ; "request_id", `String request_id
             ; "reason", Keeper_msg_async.access_rejection_to_json rejection
             ]))
;;

let status_result ~config ~meta ~request_id =
  status_result_for_invocation ~config ~meta ~request_id ()
;;

let cancel_result
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~request_id
  =
  let tool_name = Catalog.cancel_tool_name in
  let start_time = Tool_timing.start () in
  let result =
    Keeper_msg_async.cancel
      ~base_path:config.base_path
      ~caller:meta.name
      request_id
  in
  let data =
    with_tool_kind_field
      Catalog.cancel_tool_kind
      (Keeper_msg_async.cancel_result_to_json ~request_id result)
  in
  match result with
  | Keeper_msg_async.Cancellation_requested _ ->
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Runtime_failure
      ~ok:true
      data
  | Keeper_msg_async.Cancel_not_found
  | Keeper_msg_async.Cancel_already_terminal _ ->
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Workflow_rejection
      ~ok:false
      data
  | Keeper_msg_async.Cancel_rejected _ ->
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Policy_rejection
      ~ok:false
      data
  | Keeper_msg_async.Cancel_unreadable _
  | Keeper_msg_async.Cancel_worker_ownership_unknown _
  | Keeper_msg_async.Cancel_persistence_failed _
  | Keeper_msg_async.Cancel_worker_signal_failed _
  | Keeper_msg_async.Cancel_state_invariant_failed _ ->
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Runtime_failure
      ~ok:false
      data
;;

let make_request_control_tool
      ~(config : Workspace.config)
      ~name
      ~description
      ~input_schema
      ~descriptor
      ~on_rejected
      ~handle
  =
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~descriptor
    ~base_path:config.base_path
    ~name
    ~description
    ~input_schema
    (fun execution_env input ->
      let dispatch_result =
        let start_time = Tool_timing.start () in
      match
        Tool_input_validation.validate_args
          ~schema:input_schema
          ~name
          ~args:input
          ()
      with
      | Error rejection -> on_rejected execution_env; rejection
      | Ok _ ->
        (match request_id_of_validated_input input with
         | Some request_id -> handle execution_env request_id
         | None ->
           on_rejected execution_env;
           Tool_result.runtime_err
             ~tool_name:name
             ~start_time
             "validated composition request input lost request_id")
      in
      (* task-3268: status/cancel bypass the exec handler, so emit the shared
         dispatch observers here with the honest typed result (#38824). *)
      Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some dispatch_result);
      dispatch_result)
;;
