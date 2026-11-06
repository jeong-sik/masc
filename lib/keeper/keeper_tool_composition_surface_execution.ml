module Executor = Keeper_tool_plan_executor
module Journal = Keeper_tool_execution_journal
module Plan = Keeper_tool_plan
open Keeper_tool_composition_projection

let project_execution_result ~base_path ~plan ~execution result =
  let projection =
    match Keeper_tool_plan.exports plan with
    | [] -> Tool_output.Reference_only
    | _ :: _ -> Tool_output.Inline_with_structured_diagnostic
  in
  Result.bind
    (Keeper_composition_result.project ~base_path ~plan ~execution result)
    (Tool_bridge.attach_artifact_manifest ~projection ~base_path)
;;

let record_skill_composition_evidence
      ~on_publication_failure
      ~config
      ~reference
      ~composition_run_id
      ~request_id
      ~parent_invocation
      ~meta
      ~composition_tool
      ~composition_execution
      ~execution
      ~result =
  let report detail =
    on_publication_failure detail;
    Log.Keeper.warn
      "Skill composition evidence publication failed: tool=%s run=%s error=%s"
      composition_tool
      (Keeper_tool_plan.Composition_run_id.to_string composition_run_id)
      detail;
    (try
       Telemetry_coverage_gap.record
         ~masc_root:(Workspace.masc_dir config)
         ~source:"skill_composition_evidence"
         ~producer:"keeper_tool_composition_surface"
         ~durable_store:"skill-composition-evidence-v1"
         ~dashboard_surface:"/api/v1/skills/evidence"
         ~stale_reason:"skill_composition_evidence_publication_failed"
         ~keeper_name:meta.Keeper_meta_contract.name
         ~error:detail
         ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         "Skill composition evidence coverage-gap publication also failed: tool=%s error=%s"
         composition_tool
         (Printexc.to_string exn))
  in
  match
    Keeper_skill_composition_evidence.make
      ~reference
      ~composition_run_id
      ~parent_invocation
      ~request_id
      ~keeper_name:meta.name
      ~composition_tool
      ~composition_execution
      ~result
      ~executor_settlements:(evidence_nodes_of_execution execution)
  with
  | Error error ->
    Keeper_skill_composition_evidence.error_to_string error |> report
  | Ok evidence ->
    (match Keeper_skill_composition_evidence.save_latest config evidence with
     | Error error ->
       Keeper_skill_composition_evidence.error_to_string error |> report
     | Ok Keeper_skill_composition_evidence.Saved -> ()
     | Ok
         (Keeper_skill_composition_evidence.Saved_with_lock_release_error error) ->
       Log.Keeper.warn
         "Skill composition evidence published but lock release failed: tool=%s run=%s error=%s"
         composition_tool
         (Keeper_tool_plan.Composition_run_id.to_string composition_run_id)
         (File_lock_eio.durable_lock_error_to_string error))
;;

let async_parent_invocation ~request_id source =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id:("composition-async:" ^ request_id)
    ~turn:(Agent_core.Tool_contract.Invocation.turn source)
    ~schedule:(Agent_core.Tool_contract.Invocation.schedule source)
    ~completion:Agent_core.Tool_contract.Continue_after_success
;;

(* The keeper turn the tool-call ledger files the composition's calls under:
   the turn context snapshot taken when the composition was invoked. *)
let keeper_turn_id_of turn_context () =
  Option.bind turn_context (fun (context : Keeper_tool_call_log_context.turn_context) ->
    context.keeper_turn_id)

let source_observation_of_context turn_context : Journal.source_observation option =
  Option.map (fun (context : Keeper_tool_call_log_context.turn_context) ->
    ({trace_id=Option.bind context.trace_id (fun id ->
        match Keeper_id.Trace_id.of_string id with Ok id -> Some id | Error _ -> None);
      session_id=context.session_id;
      keeper_turn_id=context.keeper_turn_id;answer_source_ids=context.answer_source_ids}
      : Journal.source_observation)) turn_context

let original_source_context ~(source : Journal.source)
    ~(observation : Journal.source_observation option) turn_context =
  let context = match turn_context with
    | Some context -> context | None -> Keeper_tool_call_log_context.empty_turn_context in
  let trace_id, session_id, keeper_turn_id, answer_source_ids = match observation with
    | None ->
        Log.Keeper.info ~keeper_name:source.keeper_name
          "resumed composition run=%s source_turn=%d has no recorded source_observation (resuming_trace_id=%s); leaving producer provenance absent"
          (Plan.Composition_run_id.to_string source.composition_run_id)
          source.source_turn
          (Option.value ~default:"none" context.trace_id);
        None, None, None, []
    | Some observation ->
        let answer_source_ids = match observation.trace_id, observation.keeper_turn_id with
          | Some _, Some _ -> observation.answer_source_ids
          | None, _ | _, None -> [] in
        Option.map Keeper_id.Trace_id.to_string observation.trace_id,
        observation.session_id, observation.keeper_turn_id, answer_source_ids in
  (* The resumed run owns the operational environment, not missing producer
     coordinates. Mixing a current trace with an original turn would fabricate
     provenance for Ask and any nested composition that captures this context. *)
  Some {context with task_id=source.source_task_id;turn=Some source.source_turn;
    trace_id;session_id;keeper_turn_id;answer_source_ids}
;;

let execute_keeper_plan ~capability_authority =
  match capability_authority with
  | Keeper_tool_runtime.Frozen_surface capability_surface ->
    Executor.execute_keeper ~capability_surface
  | Keeper_tool_runtime.Compatibility_meta ->
    Executor.Compatibility.execute_keeper
;;

let isolate_gate_context ~gate_causal_context ~gate_context ~record_gate_result =
  match gate_causal_context with
  | Some parent ->
    let local = Keeper_gate_causal_context.fork parent in
    let record ~operation ~input result =
      Keeper_gate_causal_context.record_tool_result local ~operation ~input result;
      match record_gate_result with
      | Some record -> record ~operation ~input result
      | None -> Keeper_gate_causal_context.record_tool_result parent ~operation ~input result
    in
    Some (fun () -> Keeper_gate_causal_context.snapshot local), Some record
  | None -> gate_context, record_gate_result
;;

let with_ready_inline_files ~config ~meta ~source ~plan ~prepared_files
    ~gate_causal_context ~gate_context ~record_gate_result run =
  let invoke ready_files =
    let gate_context, record_gate_result =
      if Option.is_some ready_files then
        isolate_gate_context ~gate_causal_context ~gate_context ~record_gate_result
      else gate_context, record_gate_result in
    run ready_files gate_context record_gate_result in
  match prepared_files, Fs_compat.execution_context () with
  | Some _, _ | None, Fs_compat.Non_eio -> invoke None
  | None, Fs_compat.Eio_fiber ->
    Eio.Switch.run (fun sw ->
      let ready_files = match gate_causal_context, gate_context with
        | None, Some _ -> None
        | Some _, _ | None, None ->
          Keeper_prepared_inline_files.Ready.create ~sw ~config ~meta ~source plan in
      invoke ready_files)
;;
