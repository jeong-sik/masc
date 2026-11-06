module Catalog = Keeper_tool_composition_catalog
module Executor = Keeper_tool_plan_executor
module Journal = Keeper_tool_execution_journal
open Keeper_tool_composition_projection
open Keeper_tool_composition_surface_schema

let observe_node_result
      ?on_receipt_committed
      ~composition_tool
      ~composition_execution
      ~composition_tool_kind
      ~composition_run_id
      ~parent_invocation
      ~meta
      ~(turn_context : Keeper_tool_call_log_context.turn_context)
      (result : Executor.node_result)
  =
  let observed_result = node_observation_result result in
  let committed = ref false in
  let observe () =
    let context = turn_context in
    let schedule = result.schedule in
    Keeper_tool_call_log.log_call
      ~keeper_name:meta.Keeper_meta_contract.name
      ~tool_name:result.tool_name
      ~input:result.input
      ~output_text:(Tool_result.message observed_result)
      ?execution_evidence:
        (Keeper_tool_call_log.execution_evidence_of_metadata
           (Tool_result.metadata observed_result))
      ~wire_outcome:(wire_outcome_of_result observed_result)
      ~duration_ms:(Tool_result.duration_ms observed_result)
      ~model:(Keeper_hooks_agent_core_types.current_keeper_model meta)
      ?agent_name:context.agent_name
      ?turn_kind:context.turn_kind
      ?lane:context.lane
      ?tool_choice:context.tool_choice
      ?thinking_enabled:context.thinking_enabled
      ?prompt_fingerprint:context.prompt_fingerprint
      ~execution_id:result.execution_id
      ?physical_execution_id:result.physical_execution_id
      ~tool_use_id:result.tool_use_id
      ~planned_index:schedule.planned_index
      ~batch_index:schedule.batch_index
      ~batch_size:schedule.batch_size
      ~execution_mode:schedule.execution_mode
      ~typed_result:observed_result
      (* Schema rejection changes the node disposition, not the observation
         already produced by that execution. Keep its durable roots even when
         the validated result cannot carry a successful payload. *)
      ~artifact_refs:(Tool_result.retained_artifacts result.result)
      ~result_bytes:result.result_bytes
      ?truncated_to:result.truncated_to
      ~composition_tool
      ~composition_run_id:
        (Keeper_tool_plan.Composition_run_id.to_string composition_run_id)
      ~composition_node_id:(Keeper_tool_plan.Node_id.to_string result.node_id)
      ~composition_execution
      ~composition_tool_kind
      ~parent_tool_use_id:
        (Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation)
      ?trace_id:context.trace_id
      ?session_id:context.session_id
      ~answer_source_ids:context.answer_source_ids
      ~turn:(Agent_core.Tool_contract.Invocation.turn parent_invocation)
      ?keeper_turn_id:context.keeper_turn_id
      ?task_id:context.task_id
      ?sandbox_profile:context.sandbox_profile
      ?sandbox_root:context.sandbox_root
      ?sandbox_roots:context.sandbox_roots
      ?network_mode:context.network_mode
      ?runtime_profile:context.runtime_profile
      ~on_committed:(fun () ->
        committed := true;
        Option.iter (fun record -> record result.execution_id) on_receipt_committed)
      ();
    if not !committed
    then failwith "composition telemetry commit callback was not delivered";
    let fields =
      [ "type", `String "keeper_tool_call_evidence_committed"
      ; "name", `String meta.name
      ; "tool_name", `String result.tool_name
      ; ( "composition_run_id"
        , `String
            (Keeper_tool_plan.Composition_run_id.to_string composition_run_id) )
      ; ( "composition_node_id"
        , `String (Keeper_tool_plan.Node_id.to_string result.node_id) )
      ; "composition_tool", `String composition_tool
      ; ( "composition_execution"
        , `String
            (Keeper_tool_composition_catalog.execution_mode_to_string
               composition_execution) )
      ; ( "composition_tool_kind"
        , `String
            (Keeper_tool_descriptor.tool_kind_to_string composition_tool_kind) )
      ; ( "parent_tool_use_id"
        , `String
            (Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation) )
      ; "turn", `Int (Agent_core.Tool_contract.Invocation.turn parent_invocation)
      ; "execution_id", Ids.Execution_id.to_yojson result.execution_id
      ; "duration_ms", `Float (Tool_result.duration_ms observed_result)
      ; "disposition", `String (Tool_result.string_of_disposition observed_result)
      ; ( "wire_outcome"
        , `String
            (Tool_result.string_of_tool_call_outcome
               (wire_outcome_of_result observed_result)) )
      ; "result_bytes", `Int result.result_bytes
      ; "truncated_to", Json_util.int_opt_to_json result.truncated_to
      ; "planned_index", `Int schedule.planned_index
      ; "batch_index", `Int schedule.batch_index
      ; "batch_size", `Int schedule.batch_size
      ; ( "execution_mode"
        , Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode )
      ; "ts_unix", `Float (Time_compat.now ())
      ; "tool_use_id", `String result.tool_use_id
      ]
    in
    Sse.broadcast (`Assoc fields)
  in
  try
    observe ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    if not !committed && Tool_result.retained_artifacts result.result <> [] then (
      Log.Keeper.error
        "composition retained result receipt failed; execution stopped: tool=%s node=%s error=%s"
        composition_tool
        (Keeper_tool_plan.Node_id.to_string result.node_id)
        (Printexc.to_string exn);
      Error ("retained composition observation receipt failed: " ^ Printexc.to_string exn)
    ) else (
      Log.Keeper.warn
        "composition action telemetry degraded without changing execution: tool=%s node=%s error=%s"
        composition_tool
        (Keeper_tool_plan.Node_id.to_string result.node_id)
        (Printexc.to_string exn);
      Ok ()
    )
;;

let observe_composition_run_summary
      ~composition_tool
      ?skill_reference
      ~composition_execution
      ~composition_tool_kind
      ~composition_run_id
      ~parent_invocation
      ~meta
      ~turn_context
      ~input
      ~output_text
      ~success
      ~duration_ms
      ?typed_result
      ()
  =
  let field get = Option.bind turn_context get in
  try
    let committed = ref false in
    let schedule = Agent_core.Tool_contract.Invocation.schedule parent_invocation in
    Keeper_tool_call_log.log_call
      ~keeper_name:meta.Keeper_meta_contract.name
      ~tool_name:composition_run_summary_tool_name
      ~input
      ~output_text
      ~wire_outcome:(if success then Tool_result.Ok else Tool_result.Error)
      ~duration_ms
      ~record_kind:Keeper_tool_call_log.Composition_run
      ~model:(Keeper_hooks_agent_core_types.current_keeper_model meta)
      ?agent_name:(field (fun context -> context.Keeper_tool_call_log_context.agent_name))
      ?turn_kind:(field (fun context -> context.turn_kind))
      ?lane:(field (fun context -> context.lane))
      ?tool_choice:(field (fun context -> context.tool_choice))
      ?thinking_enabled:(field (fun context -> context.thinking_enabled))
      ?prompt_fingerprint:(field (fun context -> context.prompt_fingerprint))
      ~tool_use_id:(Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation)
      ~planned_index:schedule.planned_index
      ~batch_index:schedule.batch_index
      ~batch_size:schedule.batch_size
      ~execution_mode:schedule.execution_mode
      ?typed_result
      ~composition_tool
      ?skill_reference
      ~composition_run_id:
        (Keeper_tool_plan.Composition_run_id.to_string composition_run_id)
      ~composition_execution
      ~composition_tool_kind
      ~parent_tool_use_id:
        (Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation)
      ?trace_id:(field (fun context -> context.trace_id))
      ?session_id:(field (fun context -> context.session_id))
      ~turn:(Agent_core.Tool_contract.Invocation.turn parent_invocation)
      ?keeper_turn_id:(field (fun context -> context.keeper_turn_id))
      ?task_id:(field (fun context -> context.task_id))
      ?sandbox_profile:(field (fun context -> context.sandbox_profile))
      ?sandbox_root:(field (fun context -> context.sandbox_root))
      ?sandbox_roots:(field (fun context -> context.sandbox_roots))
      ?network_mode:(field (fun context -> context.network_mode))
      ?runtime_profile:(field (fun context -> context.runtime_profile))
      ~result_bytes:(String.length output_text)
      ~on_committed:(fun () -> committed := true)
      ();
    if not !committed
    then failwith "composition run summary commit callback was not delivered"
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn
      "composition run summary telemetry degraded without changing execution: tool=%s run=%s error=%s"
      composition_tool
      (Keeper_tool_plan.Composition_run_id.to_string composition_run_id)
      (Printexc.to_string exn)
;;

let observe_async_run_settlement
      ~composition_tool
      ?skill_reference
      ~composition_tool_kind
      ~composition_run_id
      ~parent_invocation
      ~meta
      ~turn_context
      settlement
  =
  match settlement with
  | Keeper_msg_async.Status_settlement
      { entry; durability = Keeper_msg_async.Durable; origin = _ } ->
    let terminal =
      match Journal.completion_pending ~base_path:entry.base_path entry with
      | Ok true | Error _ -> None
      | Ok false ->
      match entry.Keeper_msg_async.status with
      | Keeper_msg_async.Done { ok; body; data = _ } -> Some (ok, body)
      | Keeper_msg_async.Lost { reason } -> Some (false, reason)
      | Keeper_msg_async.Cancelled { reason; cancelled_by } ->
        Some (false, Printf.sprintf "%s: %s" cancelled_by reason)
      | Keeper_msg_async.Persistence_failed { attempted_status; reason } ->
        Some (false, Printf.sprintf "persisting %s failed: %s" (Keeper_msg_async.persistence_target_to_string attempted_status) reason)
      | Keeper_msg_async.Queued
      | Keeper_msg_async.Running
      | Keeper_msg_async.Cancelling _ -> None
      | Keeper_msg_async.Waiting_for_dependencies _ -> None
    in
    Option.iter
      (fun (success, output_text) ->
         match entry.completed_at with
         | None ->
           Log.Keeper.warn
             "composition run summary omitted: terminal request has no completed_at tool=%s request_id=%s"
             composition_tool
             entry.request_id
         | Some completed_at ->
           let duration_ms =
             Keeper_timing.elapsed_duration_ms
               ~start_time:entry.submitted_at
               ~end_time:completed_at
             |> Float.of_int
           in
           observe_composition_run_summary
             ~composition_tool
             ?skill_reference
             ~composition_execution:Catalog.Async
             ~composition_tool_kind
             ~composition_run_id
             ~parent_invocation
             ~meta
             ~turn_context
             ~input:(`Assoc [ "request_id", `String entry.request_id ])
             ~output_text
             ~success
             ~duration_ms
             ())
      terminal
  | Keeper_msg_async.Status_settlement
      { durability = Keeper_msg_async.Volatile_persistence_failure; _ }
  | Keeper_msg_async.Settlement_projection_error _ -> ()
;;

let result_of_execution ~tool_name ~tool_kind ~start_time = function
  | Ok settled ->
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`Assoc
            (("composition_tool", `String tool_name)
             :: tool_kind_field tool_kind
             :: [ "actions", `List (List.map node_result_to_json settled) ]))
      ()
  | Error
      ({ Executor.cause = Executor.Tool_did_not_complete result; _ } as failure :
        Executor.failure) ->
    let data = failure_data ~tool_name ~tool_kind failure in
    (match result.result with
     | Tool_result.Deferred payload ->
       Tool_result.make_deferred
         ~tool_name
         ~start_time
         ~data
         ?metadata:payload.metadata
         ()
     | Tool_result.Failed payload ->
       Tool_result.make_err
         ~tool_name
         ~class_:payload.class_
         ~effect_disposition:failure.effect_disposition
         ~start_time
         ~data
         ?metadata:payload.metadata
         (Yojson.Safe.to_string data)
     | Tool_result.Completed _ ->
       Tool_result.make_err
         ~tool_name
         ~class_:Tool_result.Runtime_failure
         ~start_time
         ~data
         "composition executor reported a completed result as incomplete")
  | Error
      ({ Executor.cause =
           ( Executor.Plan_execution_failed _
           | Executor.Node_observation_failed _
           | Executor.Run_journal_rejected _
           | Executor.Outer_completion_mismatch _ )
       ; _
       } as failure) ->
    let data = failure_data ~tool_name ~tool_kind failure in
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition:failure.effect_disposition
      ~start_time
      ~data
      (Yojson.Safe.to_string data)
;;
