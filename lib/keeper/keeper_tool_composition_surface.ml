module Catalog = Keeper_tool_composition_catalog
module Executor = Keeper_tool_plan_executor
module Journal = Keeper_tool_execution_journal
module Plan = Keeper_tool_plan
module Activation_ledger = Keeper_skill_activation_ledger
open Keeper_tool_composition_projection

open Result.Syntax

type owner_metadata_refusal =
  | Owner_metadata_missing
  | Owner_metadata_mismatch

type continuation_refusal =
  | Current_leaf_denied of Keeper_composition_draft.continuation_refusal
  | Original_producer_absent of Skill_reference.t
  | Original_producer_changed of Skill_reference.t
  | Original_owner_metadata_refused of owner_metadata_refusal

let continuation_refusal_to_json = function
  | Current_leaf_denied refusal -> Keeper_composition_draft.continuation_refusal_to_json refusal
  | Original_producer_absent reference -> `Assoc
      ["kind",`String "original_producer_absent";"skill_reference",Skill_reference.to_yojson reference]
  | Original_producer_changed reference -> `Assoc
      ["kind",`String "original_producer_changed";"skill_reference",Skill_reference.to_yojson reference]
  | Original_owner_metadata_refused Owner_metadata_missing -> `Assoc
      ["kind",`String "owner_metadata_missing"]
  | Original_owner_metadata_refused Owner_metadata_mismatch -> `Assoc
      ["kind",`String "owner_metadata_mismatch"]

let validate_original_producer_activation ~config (source : Journal.source) =
  match source.producer with
  | Journal.Prepared | Named {origin=Nested _;_} -> Ok ()
  | Named {origin=Standalone;activation=None;_} -> Error "original named activation context is missing"
  | Named {origin=Standalone;activation=Some bound;tool_name;skill_reference} ->
    let* original = Keeper_skill_activation_recorder.find_bound_composition ~config bound
        ~tool_use_id:source.parent_tool_use_id ~source_turn:source.source_turn ~tool_name skill_reference
        |> Result.map_error Keeper_skill_activation_recorder.error_to_string in
    (match original with Some _ -> Ok () | None -> Error "original named activation is missing")

let composition_run_summary_tool_name = "keeper_composition_run_summary"

let request_id_of_validated_input = function
  | `Assoc fields ->
    (match List.assoc_opt "request_id" fields with
     | Some (`String request_id) -> Some request_id
     | Some _ | None -> None)
  | _ -> None
;;

let entry_description (entry : Catalog.entry) =
  Option.value
    ~default:
      (match entry.execution with
       | Catalog.Inline ->
         "Execute the validated Keeper composition " ^ entry.name ^ "."
       | Catalog.Async ->
         "Start the validated read-only Keeper composition "
         ^ entry.name
         ^ " and return its durable request id.")
    entry.description
;;


;;

let schema_tool ~name ~description ~input_schema =
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~name
    ~description
    ~input_schema
    (fun _ _ -> invalid_arg "schema-only Keeper tool cannot execute")
;;

let skill_tool_schema : Masc_domain.tool_schema = Tool_schemas_skill.schema

type instruction_skill =
  { reference : Skill_reference.t
  ; description : string
  ; body : string
  ; resource_location : resource_location option
  }

and resource_location =
  { source_root : string
  ; directory : string
  ; resource_read_max_bytes : Skill_source_config.resource_read_max_bytes
  }

type composition_skill =
  { reference : Skill_reference.t
  ; entry : Catalog.entry
  }

(* Each line carries what a call needs and nothing else: the identity, copyable
   straight into the tool's [identity] argument. It used to carry the whole
   reference, whose 64-hex content_revision is the larger half of every line and
   is no longer asked for — the turn's frozen list decides that (RFC-0411 §4.2).
   The revision comes back only on a refusal, where it is the one thing that can
   still separate two Skills sharing an identity. *)
let instruction_skill_description (instruction_skills : instruction_skill list) =
  let listed =
    instruction_skills
    |> List.map (fun (skill : instruction_skill) ->
         Printf.sprintf
           "%s: %s"
           (Skill_reference.identity_to_yojson skill.reference.identity
            |> Yojson.Safe.to_string)
           skill.description)
    |> String.concat "\n"
  in
  skill_tool_schema.description ^ "\n\nAvailable:\n" ^ listed
;;

(* Every refusal that turns on the reference answers with the references the
   keeper actually carries. A caller without the revision at hand — the log
   shows empty strings and copied placeholders — has to be handed the exact
   value here, because nothing else on its surface can say it (task-828). *)
let carried_references_text (instruction_skills : instruction_skill list) =
  match instruction_skills with
  | [] -> "(none)"
  | skills ->
    String.concat
      ", "
      (List.map
         (fun (skill : instruction_skill) ->
            Skill_reference.to_yojson skill.reference |> Yojson.Safe.to_string)
         skills)
;;

type 'evidence schema_tool_origin =
  | Declared_composition of 'evidence
  | Async_status
  | Async_cancel
  | Transient_prepare
  | Transient_run

let composition_schema_tool (entry : Catalog.entry) =
  schema_tool
    ~name:(Catalog.tool_name entry)
    ~description:(entry_description entry)
    ~input_schema:(Catalog.input_schema_of_params entry.params)
;;

(* Row selection and order are shared by schemas and the names-only view.
   Retain entries beside caller evidence until the requested projection. *)
let schema_tool_origins ~include_drafts ~skill_compositions =
  let compositions = List.map (fun row -> Declared_composition row) skill_compositions in
  let controls =
    if include_drafts || Catalog.requires_async_controls (List.map fst skill_compositions)
    then [Async_status; Async_cancel]
    else [] in
  let drafts = if include_drafts then [Transient_prepare; Transient_run] else [] in
  compositions @ controls @ drafts
;;

let schema_tool_name_rows ?(include_drafts = true) ?(skill_compositions = []) () =
  schema_tool_origins ~include_drafts ~skill_compositions
  |> List.map (function
       | Declared_composition (entry, evidence) ->
           Declared_composition evidence, Catalog.tool_name entry
       | Async_status -> Async_status, Catalog.status_tool_name
       | Async_cancel -> Async_cancel, Catalog.cancel_tool_name
       | Transient_prepare -> Transient_prepare, Catalog.prepare_tool_name
       | Transient_run -> Transient_run, Catalog.run_tool_name)
;;

let schema_tool_rows ?(include_drafts = true) ?(skill_compositions = []) () =
  schema_tool_origins ~include_drafts ~skill_compositions
  |> List.map (function
       | Declared_composition (entry, evidence) ->
           Declared_composition evidence, composition_schema_tool entry
       | Async_status ->
           Async_status, schema_tool
             ~name:Catalog.status_tool_name
             ~description:Tool_schemas_composition_control.status_schema.description
             ~input_schema:Tool_schemas_composition_control.status_schema.input_schema
       | Async_cancel ->
           Async_cancel, schema_tool
             ~name:Catalog.cancel_tool_name
             ~description:Tool_schemas_composition_control.cancel_schema.description
             ~input_schema:Tool_schemas_composition_control.cancel_schema.input_schema
       | Transient_prepare ->
           Transient_prepare, schema_tool
             ~name:Catalog.prepare_tool_name
             ~description:Keeper_composition_draft.prepare_schema.description
             ~input_schema:Keeper_composition_draft.prepare_schema.input_schema
       | Transient_run ->
           Transient_run, schema_tool
             ~name:Catalog.run_tool_name
             ~description:Keeper_composition_draft.run_schema.description
             ~input_schema:Keeper_composition_draft.run_schema.input_schema)
;;

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
             "validated composition request input lost request_id"))
;;

(* Progressive disclosure keeps names and descriptions in the tool
   description. The frozen body arrives only after an exact-reference call. *)
(* Declared in [config/tools/keeper_skill.toml] with every other tool rather
   than built here. Which skills are readable is workspace state and is
   appended below; the argument's shape and the sentence saying when to reach
   for the tool are not, and the model-prose ratchet is what says so. *)
let skill_reference_input_schema = skill_tool_schema.input_schema

let instruction_skill ?resource_location ~reference ~description ~body () =
  { reference; description; body; resource_location }
;;

let instruction_skills_of_catalog skill_catalog =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.surface with
           | Some reference, Keeper_skill_catalog.Instruction ->
             let resource_location =
               match skill.provenance with
               | Some
                   { source_root = Some source_root
                   ; resource_read_max_bytes = Some resource_read_max_bytes
                   ; directory
                   ; _
                   } ->
                 Some
                   { source_root; directory; resource_read_max_bytes }
               | Some { source_root = None; _ }
               | Some { resource_read_max_bytes = None; _ }
               | None ->
                 None
             in
             Some
               (instruction_skill
                  ?resource_location
                  ~reference
                  ~description:skill.description
                  ~body:skill.body
                  ())
           | None, _ | Some _, Keeper_skill_catalog.Composition _ ->
             None)
;;

let instruction_skill_schema_tool
      ~(instruction_skills : instruction_skill list)
  =
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~name:skill_tool_schema.name
    ~description:(instruction_skill_description instruction_skills)
    ~input_schema:skill_reference_input_schema
    (fun _ _ -> invalid_arg "schema-only instruction Skill tool cannot execute")
;;

let activation_failure ?reference ~tool_name ~start_time error =
  let reference_field =
    Option.to_list
      (Option.map
         (fun reference -> "reference", Skill_reference.to_yojson reference)
         reference)
  in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    ~data:
      (`Assoc
         (( "skill_activation_error"
          , Keeper_skill_activation_recorder.error_to_yojson error )
          :: reference_field))
    (Keeper_skill_activation_recorder.error_to_string error)
;;

type skill_input_error =
  | Invalid_skill_reference
  | Duplicate_resource_path
  | Invalid_resource_path of Skill_resource_path.error

let skill_reference_and_resource_path input =
  match input with
  | `Assoc fields ->
    let reference_json =
      `Assoc (List.filter (fun (field, _) -> not (String.equal field "file")) fields)
    in
    let resource_fields =
      List.filter_map
        (fun (field, value) -> if String.equal field "file" then Some value else None)
        fields
    in
    (match Skill_reference.request_of_yojson reference_json with
     | Error _ -> Error Invalid_skill_reference
     | Ok reference ->
       (match resource_fields with
        | [] -> Ok (reference, None)
        | [ `String value ] ->
          Skill_resource_path.of_string value
          |> Result.map (fun resource_path -> reference, Some resource_path)
          |> Result.map_error (fun error -> Invalid_resource_path error)
        | [ _ ] -> Error (Invalid_resource_path Skill_resource_path.Empty)
        | _ :: _ :: _ -> Error Duplicate_resource_path))
  | _ ->
    Error Invalid_skill_reference
;;

type instruction_resource =
  | Resource_missing
  | Resource_too_large of
      { observed_bytes : int
      ; max_bytes : int
      }
  | Resource_loaded of string

let load_instruction_resource location relative_path =
  let skill_root = Filename.concat location.source_root location.directory in
  let path = Skill_resource_path.append_to ~root:skill_root relative_path in
  let max_bytes =
    Skill_source_config.resource_read_max_bytes_to_int
      location.resource_read_max_bytes
  in
  Fs_compat.load_owned_regular_file_prefix
    ~ownership_root:location.source_root
    ~max_bytes
    path
  |> Result.map (function
    | None -> Resource_missing
    | Some { Fs_compat.truncated = true; file_size; _ } ->
      Resource_too_large { observed_bytes = file_size; max_bytes }
    | Some { content; truncated = false; _ } -> Resource_loaded content)
;;

let make_instruction_skill_tool
      ~(config : Workspace.config)
      ?record_activation
      ?assess_applicability
      ?on_result
      ~instruction_skills
      ()
  =
  let name = Catalog.skill_tool_name in
  let description = instruction_skill_description instruction_skills in
  let observe handler execution_env input =
    let result = handler execution_env input in
    Option.iter (fun callback -> callback ~input result) on_result;
    result
  in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~base_path:config.base_path
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name
    ~description
    ~input_schema:skill_reference_input_schema
    (observe (fun execution_env input ->
      let start_time = Tool_timing.start () in
      match
        Tool_input_validation.validate_args ~schema:skill_reference_input_schema ~name
          ~args:input ()
      with
      | Error rejection -> rejection
      | Ok _ ->
        (match Agent_core.Tool.Execution_env.invocation execution_env with
         | None ->
           Tool_result.runtime_err
             ~tool_name:name
             ~start_time
             "keeper_skill execution requires Agent-Core invocation identity"
         | Some invocation ->
        (match skill_reference_and_resource_path input with
         | Error Invalid_skill_reference ->
           Tool_result.make_err
             ~tool_name:name
             ~class_:Tool_result.Workflow_rejection
             ~start_time
             (Printf.sprintf
                "keeper_skill requires one canonical exact Skill reference; \
                 this keeper carries: %s"
                (carried_references_text instruction_skills))
         | Error Duplicate_resource_path ->
           Tool_result.make_err
             ~tool_name:name
             ~class_:Tool_result.Workflow_rejection
             ~start_time
             "keeper_skill accepts at most one resource file"
         | Error (Invalid_resource_path error) ->
           Tool_result.make_err
             ~tool_name:name
             ~class_:Tool_result.Workflow_rejection
             ~start_time
             (Skill_resource_path.error_to_string error)
         | Ok (asked, resource_path) ->
           (* A pinned request is matched whole, as before: a revision the
              caller spelled out is honoured or refused, never replaced. A
              request that named the Skill and left the revision open is
              resolved against this turn's frozen list — the same list the
              pinned match searches, so nothing new is reachable by dropping
              the revision.

              Two carried Skills sharing an identity cannot be told apart by
              name, so that ask is refused rather than answered with a guess;
              the refusal carries the exact references, which is the one
              contract that can still separate them. RFC-0411 §4.2, §4.3. *)
           (match
              match asked with
              | Skill_reference.Pinned reference ->
                List.filter
                  (fun (skill : instruction_skill) ->
                     Skill_reference.equal skill.reference reference)
                  instruction_skills
              | Skill_reference.By_identity identity ->
                List.filter
                  (fun (skill : instruction_skill) ->
                     Skill_reference.equal_identity
                       skill.reference.identity
                       identity)
                  instruction_skills
            with
            | _ :: _ :: _ ->
              Tool_result.make_err
                ~tool_name:name
                ~class_:Tool_result.Workflow_rejection
                ~start_time
                (Printf.sprintf
                   "this keeper carries more than one Skill under that name, so \
                    the name alone cannot say which; call again with \
                    content_revision. Carried: %s"
                   (carried_references_text instruction_skills))
            | [ skill ] ->
              let reference = skill.reference in
              let skill_tool_use_id =
                Agent_core.Tool_contract.Invocation.tool_use_id invocation
              in
              let success ~wire_content metadata =
                Tool_result.make_ok
                  ~tool_name:name
                  ~start_time
                  ~data:(`String wire_content)
                  ~metadata:
                    (`Assoc
                       (("reference", Skill_reference.to_yojson reference)
                        :: ("skill_tool_use_id", `String skill_tool_use_id)
                        :: metadata))
                  ()
              in
              let record_and_return ~content ~wire_content metadata =
                let wire_bytes = String.length wire_content in
                if wire_bytes > Common.max_tool_result_wire_bytes
                then
                  Tool_result.make_err
                    ~tool_name:name
                    ~class_:Tool_result.Workflow_rejection
                    ~start_time
                    ~data:
                      (`Assoc
                         [ ( "skill_content_error"
                           , `Assoc
                               [ "kind", `String "provider_inline_too_large"
                               ; "observed_bytes", `Int wire_bytes
                               ; "max_bytes", `Int Common.max_tool_result_wire_bytes
                               ] )
                         ])
                    (Printf.sprintf
                       "Skill content does not fit the provider inline tool-result boundary: observed_bytes=%d max_bytes=%d"
                       wire_bytes
                       Common.max_tool_result_wire_bytes)
                else
                  let wire_content, metadata =
                    match content, assess_applicability with
                    | Keeper_skill_activation_recorder.Body body, Some assess ->
                      let assessment = assess ~reference ~body in
                      let advice =
                        let open Result.Syntax in
                        let* advice = Typesafeai_skill_applicability.model_advice assessment in
                        match advice with
                        | None -> Ok None
                        | Some advice ->
                          Prompt_registry.render_prompt_template
                            Prompt_names.skill_applicability_projection
                            ["advice", advice; "body", wire_content]
                          |> Result.map Option.some
                      in
                      let projected = match advice with
                        | Ok (Some text) -> text
                        | Ok None | Error _ -> wire_content in
                      let fits = String.length projected <= Common.max_tool_result_wire_bytes in
                      let has_advice = match advice with Ok (Some _) -> true | Ok None | Error _ -> false in
                      let metadata = match advice with
                        | Error reason -> ("applicability_projection_error", `String reason) :: metadata
                        | Ok _ -> metadata in
                      let metadata =
                        ("skill_applicability", Typesafeai_skill_applicability.to_yojson assessment)
                        :: ("applicability_advice_in_model_content", `Bool (fits && has_advice))
                        :: ("applicability_projection", `String
                              (match advice with
                               | Error _ -> "unavailable"
                               | Ok None -> "not_requested"
                               | Ok (Some _) -> if fits then "inline" else "omitted_inline_limit"))
                        :: metadata in
                      (if fits then projected else wire_content), metadata
                    | Keeper_skill_activation_recorder.Resource _, _
                    | Keeper_skill_activation_recorder.Body _, None -> wire_content, metadata
                  in
                  match record_activation with
                  | Some record ->
                    (match record ~invocation ~content reference with
                     | Error error ->
                       let failure = activation_failure ~reference ~tool_name:name ~start_time error in
                       (match List.assoc_opt "skill_applicability" metadata with
                        | None -> failure
                        | Some assessment ->
                          Tool_result.with_metadata
                            (`Assoc
                               [ "reference", Skill_reference.to_yojson reference
                               ; "skill_tool_use_id", `String skill_tool_use_id
                               ; "skill_applicability", assessment
                               ; "applicability_advice_in_model_content", `Bool false
                               ; "applicability_projection", `String "withheld_activation_failure"
                               ])
                            failure)
                     | Ok
                         ( Activation_ledger.Recorded _
                         | Activation_ledger.Already_recorded _ ) ->
                       success ~wire_content metadata)
                  | None -> success ~wire_content metadata
              in
              (match resource_path with
               | None ->
                 record_and_return
                   ~content:(Keeper_skill_activation_recorder.Body skill.body)
                   ~wire_content:skill.body
                   [ "kind", `String "skill_body"
                   ; "bytes", `Int (String.length skill.body)
                   ; ( "sha256"
                     , `String
                         Agent_core_sha256.(digest_string skill.body |> to_hex) )
                   ]
               | Some relative_path ->
                 (match skill.resource_location with
                  | None ->
                    Tool_result.runtime_err
                      ~tool_name:name
                      ~start_time
                      "the frozen Skill snapshot has no resolved resource root"
                  | Some location ->
                    (match load_instruction_resource location relative_path with
                     | Error error ->
                       Tool_result.runtime_err
                         ~tool_name:name
                         ~start_time
                         (Fs_compat.owned_regular_file_read_error_to_string error)
                     | Ok Resource_missing ->
                       Tool_result.make_err
                         ~tool_name:name
                         ~class_:Tool_result.Workflow_rejection
                         ~start_time
                         (Printf.sprintf
                            "the Skill carries no resource %S"
                            (Skill_resource_path.to_string relative_path))
                     | Ok (Resource_too_large { observed_bytes; max_bytes }) ->
                       Tool_result.make_err
                         ~tool_name:name
                         ~class_:Tool_result.Workflow_rejection
                         ~start_time
                         ~data:
                           (`Assoc
                              [ ( "skill_resource_error"
                                , `Assoc
                                    [ "kind", `String "too_large"
                                    ; ( "file"
                                      , `String
                                          (Skill_resource_path.to_string
                                             relative_path) )
                                    ; "observed_bytes", `Int observed_bytes
                                    ; "max_bytes", `Int max_bytes
                                    ] )
                              ])
                         (Printf.sprintf
                            "Skill resource too_large: observed_bytes=%d max_bytes=%d"
                            observed_bytes
                            max_bytes)
                     | Ok (Resource_loaded contents) ->
                       let relative_path_text =
                         Skill_resource_path.to_string relative_path
                       in
                       let sha256 =
                         Agent_core_sha256.(digest_string contents |> to_hex)
                       in
                       record_and_return
                         ~content:
                           (Keeper_skill_activation_recorder.Resource
                              { relative_path; contents })
                         ~wire_content:contents
                         [ "file", `String relative_path_text
                         ; "kind", `String "skill_resource"
                         ; "bytes", `Int (String.length contents)
                         ; "sha256", `String sha256
                         ])))
            | (* A reference the frozen catalog does not carry is the caller's
                 error and says so with the exact references it does carry,
                 rather than an empty
                 body the model would read as "this skill says nothing". *)
              [] ->
              Tool_result.make_err ~tool_name:name
                ~class_:Tool_result.Workflow_rejection ~start_time
                (Printf.sprintf
                   "no instruction Skill matches %s; this keeper carries: %s"
                   (match asked with
                    | Skill_reference.Pinned reference ->
                      Printf.sprintf
                        "exact reference %s"
                        (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
                    | Skill_reference.By_identity identity ->
                      Printf.sprintf
                        "identity %s"
                        (Skill_reference.identity_to_yojson identity
                         |> Yojson.Safe.to_string))
                   (carried_references_text instruction_skills)))))))
;;


(* A composition failure goes back to the model when every failed node, called
   directly, would have gone back: its handler's boundary
   (Keeper_tool_failure_boundary) with the effect disposition that node
   reported. A node read-only for the input it ran with also goes back whatever
   its handler, as #35703 let a failed read go back: it left nothing a retry
   would repeat.

   This is same-turn continuation, not permission to replay a graph after a
   provider restart. Only acknowledged atomic settlements keep the provider
   loop open, so every settled node needs a committed receipt, and a graph
   holding a terminal, nested or async node keeps its terminal fence. The
   failed result and its aggregate effect evidence stay intact.

   What a returning failure does not give back is the retry granularity of a
   direct call. A model that made the calls itself retries the one that failed;
   a model that called this macro can only call the macro again, and a node
   that already completed with an effect runs a second time. #35703 accepted
   that for a completed navigation before a failed read, and this rule keeps
   it. The result carries [settled] with each node's effect disposition, so the
   model can see what already ran and call the failed tool directly instead.
   Narrowing this to graphs with no completed effect would fence exactly the
   browser case #35703 opened. *)
let failure_returns_to_model ~plan ~committed (failure : Executor.failure) =
  let ordinary_atomic descriptor =
    match descriptor.Keeper_tool_descriptor.execution, descriptor.tool_kind with
    | Ordinary _, Atomic_tool -> true
    | Terminal, _
    | Ordinary _, (Composition_tool | Async_composition_tool) -> false
  in
  let descriptor node_id = Keeper_tool_plan.descriptor plan node_id in
  let failed_node_returns (node : Executor.node_result) =
    match descriptor node.node_id with
    | None -> false
    | Some d ->
      let disposition =
        match node.failure_effect_disposition with
        | Some disposition -> disposition
        | None -> Tool_result.Effect_outcome_unknown
      in
      ordinary_atomic d
      && (Keeper_tool_descriptor.readonly_for_input d ~input:node.input = Some true
          || not (Keeper_tool_failure_boundary.ends_turn d.Keeper_tool_descriptor.runtime_handler disposition))
  in
  let eligible (node : Executor.node_result) =
    List.exists (fun id -> id = node.execution_id) committed
    && node.output_validation_error = None
    && match node.result with
       | Tool_result.Completed _ -> true
       | Tool_result.Failed _ -> failed_node_returns node
       | Tool_result.Deferred _ -> false
  in
  List.for_all (fun (node : Keeper_tool_plan.node) ->
    match descriptor node.id with Some d -> ordinary_atomic d | None -> false)
    (Keeper_tool_plan.nodes plan)
  && match failure.cause with
     | Executor.Tool_did_not_complete node ->
       (match node.result with
        | Tool_result.Failed _ -> eligible node
          && List.exists (fun (settled : Executor.node_result) -> settled.execution_id = node.execution_id) failure.settled
          && List.for_all eligible failure.settled
        | Tool_result.Completed _ | Tool_result.Deferred _ -> false)
     | Executor.Plan_execution_failed _ | Executor.Node_observation_failed _
     | Executor.Run_journal_rejected _
     | Executor.Outer_completion_mismatch _ -> false
;;

let bind_prepared_result ~composition_run_id ~run_reference ~draft_reference result =
  let binding =
    ["composition_run_id", `String (Keeper_tool_plan.Composition_run_id.to_string composition_run_id);
     "run_artifact", Tool_output.normalized_artifact_ref_to_json run_reference;
     "draft", Tool_output.normalized_artifact_ref_to_json draft_reference] in
  let data = match Tool_result.data result with
    | `Assoc fields -> `Assoc (binding @ List.remove_assoc "composition_run_id" fields)
    | data -> `Assoc (binding @ ["result",data]) in
  let result = match result with
    | Tool_result.Completed payload -> Tool_result.Completed {payload with data}
    | Tool_result.Deferred payload -> Tool_result.Deferred {payload with data}
    | Tool_result.Failed payload -> Tool_result.Failed
      {payload with data_source=Tool_result.Explicit_data data;message=Yojson.Safe.to_string data} in
  Tool_result.with_retained_artifacts
    (run_reference :: draft_reference :: Tool_result.retained_artifacts result) result
;;

type named_admission =
  | Fresh_named of Keeper_skill_activation_recorder.t option
  | Original_child of
      { attempt : Journal.attempt
      ; parent_plan : Keeper_tool_plan.t
      ; origin : Journal.named_origin
      ; context : Keeper_skill_activation_recorder.bound_context
      }

type continuation_recovery =
  | Complete_original_result
  | Hold_original_authority of string

let continuation_recovery_of_result ~effect_disposition result =
  let hold () = Hold_original_authority (Tool_result.message result) in
  match result with
  | Tool_result.Completed _ -> Complete_original_result
  | Tool_result.Deferred _ -> hold ()
  | Tool_result.Failed failure ->
    match failure.class_ with
    | Tool_result.Policy_rejection | Tool_result.Workflow_rejection ->
      (match effect_disposition with
       | Some Tool_result.Proven_pre_effect -> Complete_original_result
       | Some (Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown)
       | None -> hold ())
    | Tool_result.Dependency_unavailable | Tool_result.Runtime_failure
    | Tool_result.Operator_cancelled -> hold ()
;;

let node_continuation_recovery (node : Executor.node_result) =
  continuation_recovery_of_result ~effect_disposition:node.failure_effect_disposition node.result

let combine_recovery left right = match left,right with
  | Hold_original_authority _,(Complete_original_result | Hold_original_authority _) -> left
  | Complete_original_result,(Complete_original_result | Hold_original_authority _) -> right

let rec async_worker_result
      ~composition_execution
      ~tool_kind
      ?skill_reference
      ?(nested_calls=[])
      ?nested_activation
      ?continuation
      ?(on_recovery_held=(fun ~request_id:_ ~reason:_ -> ()))
      ?after_child_submission
      ?before_child_dispatch
      ?keeper_turn_id
      ?before_plan_execution
      ?after_node_observation
      ?before_child_result_publication
      ?before_child_submission_publication
      ~plan
      ?journal
      ~tool_name
      ~request_id
      ~composition_run_id
      ~source_invocation
      ~request_sw
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ~turn_context
      ?clock
      ()
  =
  Eio_context.with_turn_switch request_sw
  @@ fun () ->
  let meta = match journal with
    | None -> meta
    | Some worker -> (match Journal.worker_source_observation worker with
        | Some {trace_id=Some trace_id;_} ->
            {meta with runtime={meta.Keeper_meta_contract.runtime with trace_id}}
        | Some {trace_id=None;_} | None -> meta) in
  let turn_context = match journal with
    | None -> turn_context
    | Some worker -> original_source_context ~source:(Journal.worker_source worker)
        ~observation:(Journal.worker_source_observation worker) turn_context in
  let observation_context = match journal with
    | None -> turn_context
    | Some worker -> Option.map (fun (context : Keeper_tool_call_log_context.turn_context) ->
        (* Operational fallback coordinates are not original-source evidence.
           Keep execution behavior while withholding uncaptured log identity. *)
        match Journal.worker_source_observation worker with
        | None -> {context with trace_id=None;session_id=None;keeper_turn_id=None;answer_source_ids=[]}
        | Some observation -> {context with trace_id=Option.map Keeper_id.Trace_id.to_string observation.trace_id;
            session_id=observation.session_id;keeper_turn_id=observation.keeper_turn_id}) turn_context in
  let sandbox_factory = Keeper_sandbox_factory.create ~config ~meta () in
  Eio.Switch.on_release request_sw (fun () ->
    Keeper_sandbox_factory.cleanup sandbox_factory);
  let start_time = Tool_timing.start () in
  let run_id = Keeper_tool_plan.Run_id.fresh () in
  let nested_run = Keeper_composition_nested_run.create ~calls:nested_calls ~composition_run_id
      ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent composition_run_id)
      ~parent_invocation:source_invocation ~tool_name
      ~record_activation:(Option.map (fun bound ~invocation ~tool_name ~scope ~reference ->
        Keeper_skill_activation_recorder.record_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference) nested_activation) () in
  Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions nested_run
    ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
      Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) nested_activation;
  let admission = Keeper_composition_nested_run.check_original_admissions nested_run
      ~child_history:(fun ~node_ids -> match journal with
        | Some worker -> Journal.worker_child_admission worker ~node_ids
        | None -> Error Journal.Missing_journal) in
  match admission,continuation with
  | Keeper_composition_nested_run.Original_authority_held rejection,Some continuation when Journal.continuation_dependencies continuation = [] ->
    on_recovery_held ~request_id ~reason:rejection.detail;
    Keeper_msg_async.worker_interrupted ~reason:rejection.detail
  | Keeper_composition_nested_run.Original_authority_held rejection,Some continuation ->
    on_recovery_held ~request_id ~reason:rejection.detail;
    let result = Tool_result.make_deferred ~tool_name ~start_time
        ~data:(`Assoc ["kind",`String "waiting_for_original_child_activation";"cause",rejection.data]) () in
    (match Keeper_msg_async.worker_waiting_for_dependencies
      ~dependencies:(Journal.continuation_dependencies continuation) result with
     | Ok outcome -> outcome
     | Error _ -> Keeper_msg_async.worker_finished (Tool_result.make_err ~tool_name ~start_time
         ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect rejection.detail))
  | Keeper_composition_nested_run.Original_authority_held rejection,None -> Keeper_msg_async.worker_finished (Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect rejection.detail)
  | Keeper_composition_nested_run.Original_admitted,_ ->
  (* These worker-local joins come only from the protected acceptance factory
     and the canonical reader's typed unavailable branch, never tool text. *)
  let accepted_children = ref [] in
  let unavailable_results = ref [] in
  let dispatch_compiled ~attempt ~target ~tool_use_id:_ ~node ~schedule ~input:_ =
    let start_time = Tool_timing.start () in
    let refuse detail = Executor.dispatch_result
        ~failure_effect_disposition:Tool_result.Proven_pre_effect
        (Tool_result.make_err ~tool_name:node.Plan.tool_name ~start_time
          ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect detail) in
    match target with
    | Plan.Descriptor_target _ | Plan.Child_arguments _ -> refuse "this target does not enter the native child producer"
    | Plan.Child_submission child ->
      Option.iter (fun before -> before ()) before_child_dispatch;
      let original =
        let* context = match nested_activation with
          | Some context -> Ok context
          | None -> Error "native child has no original sealed activation context" in
        let* activation = Keeper_composition_nested_run.admitted_activation nested_run
            ~alias:(Plan.child_alias child.child)
          |> Result.map_error (fun rejection -> rejection.Executor.detail) in
        let* origin,child_plan = Journal.child_origin attempt ~plan ~activation
          |> Result.map_error Journal.error_to_string in
        Ok (context,activation,origin,child_plan) in
      (match original with
       | Error detail -> refuse detail
       | Ok (context,activation,origin,child_plan) ->
         let parent_invocation = Agent_core.Tool_contract.Invocation.create
             ~tool_use_id:activation.skill_tool_use_id ~turn:activation.agent_core_turn
             ~schedule ~completion:Agent_core.Tool_contract.Continue_after_success in
         let physical_execution_id =
           Keeper_tool_call_log.invocation_execution_id ~invocation:parent_invocation in
         let result = named_async_submission_result
             ~skill_reference:(Plan.child_reference child.child) ~plan:child_plan
             ~tool_name:(Plan.child_tool_name child.child)
             ~tool_kind:Keeper_tool_descriptor.Async_composition_tool ~parent_invocation
             ~admission:(Original_child {attempt;parent_plan=plan;origin;context})
             ~on_child_accepted:(fun () -> accepted_children := node.id :: !accepted_children)
             ?before_result_publication:before_child_submission_publication
             ~config ~meta ~capability_authority ~publication_recovery
             ~ctx_snapshot ~turn_context ?clock () in
         Option.iter (fun after -> after result) after_child_submission;
         Executor.dispatch_result ~physical_execution_id result)
    | Plan.Child_result child ->
      (match Journal.child_result_binding attempt ~plan with
       | Error error ->
         unavailable_results := node.id :: !unavailable_results;
         refuse (Journal.error_to_string error)
       | Ok binding ->
         let read = match before_child_result_publication with
           | None -> Keeper_composition_dependency_result.read
           | Some before_manifest_publication ->
             Keeper_composition_dependency_result.For_testing.read
               ~after_owner_read:(fun _ -> ()) ~before_manifest_publication in
         let observed = match read ~config ~meta
             ~args:(`Assoc ["binding",Keeper_composition_dependency.composition_to_json binding]) with
           | Ok observed -> observed
           | Error observed ->
             unavailable_results := node.id :: !unavailable_results;
             observed in
         let data = match observed.data with Some data -> data | None -> `String observed.raw_output in
         let result = match observed.disposition with
           | Tool_result.Deferred () -> Tool_result.make_deferred ~tool_name:node.tool_name ~start_time
               ~data ?metadata:observed.metadata ()
           | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:node.tool_name ~start_time
               ~class_ ~effect_disposition:observed.failure_effect_disposition
               ~data ?metadata:observed.metadata observed.raw_output
           | Tool_result.Completed () ->
             (match Keeper_composition_child_exports.select
                      ~exports:(Plan.exports (Plan.child_plan child.child)) data with
              | Ok values -> Tool_result.make_ok ~tool_name:node.tool_name ~start_time ~data:(`Assoc values) ()
              | Error error -> Tool_result.make_err ~tool_name:node.tool_name ~start_time
                  ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
                  (Keeper_composition_child_exports.error_to_string error)) in
         Executor.dispatch_result ~failure_effect_disposition:observed.failure_effect_disposition
           ?deferred_kind:observed.deferred_kind
           (Tool_result.with_retained_artifacts observed.retained_artifacts result)) in
  let on_node_result = Option.map (fun turn_context ->
      observe_node_result
        ?on_receipt_committed:None
        ~composition_tool:tool_name ~composition_execution
        ~composition_tool_kind:tool_kind ~composition_run_id
        ~parent_invocation:source_invocation ~meta ~turn_context) observation_context in
  let on_node_result = match after_node_observation with
    | None -> on_node_result
    | Some after -> Some (fun node ->
        let* () = match on_node_result with None -> Ok () | Some observe -> observe node in
        after node;
        Ok ()) in
  Option.iter (fun before -> before ()) before_plan_execution;
  let execution =
    execute_keeper_plan
    ~capability_authority
    ~plan
    ~run_id
    ?journal
    ~composition_run_id
    ~parent_invocation:
      (async_parent_invocation ~request_id source_invocation)
    ~config
    ~meta
    ~publication_recovery
    ~ctx_snapshot
    ~keeper_turn_id:(match keeper_turn_id with Some callback -> callback
            | None -> keeper_turn_id_of turn_context)
    ~admit_node:(Keeper_composition_nested_run.admit_node nested_run)
    ~dispatch_compiled
    ?source_context:turn_context
    ~turn_sandbox_factory:sandbox_factory
    ?observe_node_result:on_node_result
    ?clock
      ()
  in
  let result =
    result_of_execution
      ~tool_name
      ~tool_kind
      ~start_time
      execution
  in
  let result =
    let nested_scopes = match nested_calls with [] -> None | _::_ ->
      Some (Keeper_composition_nested_run.evidence_to_json nested_run ~plan ~execution) in
    match Keeper_composition_result.project ?nested_scopes ~base_path:config.base_path ~plan ~execution result with
    | Ok result -> result
    | Error { message; _ } ->
      Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown ~start_time message
  in
  Option.iter
    (fun reference ->
       record_skill_composition_evidence
         ~on_publication_failure:(fun _ -> ())
         ~config
         ~reference
         ~composition_run_id
         ~request_id:(Some request_id)
         ~parent_invocation:source_invocation
         ~meta
         ~composition_tool:tool_name
         ~composition_execution
         ~execution
         ~result)
    skill_reference;
  let waiting_dependencies =
    let collect_waiting_dependencies settled =
      let rec collect reversed = function
        | [] -> Some (List.rev reversed)
        | (node : Executor.node_result) :: rest ->
          (match node.output_validation_error with
           | Some _ -> None
           | None ->
             (match node.result with
              | Tool_result.Completed _ -> collect reversed rest
              | Tool_result.Failed _ -> None
              | Tool_result.Deferred _ ->
                (match node.deferred_kind with
                 | Some (Keeper_tool_execution.Owned_job_result_wait id) ->
                   collect (Keeper_composition_dependency.Owned_job id :: reversed) rest
                 | Some (Keeper_tool_execution.Composition_result_wait binding) ->
                   collect (Keeper_composition_dependency.Composition_result binding :: reversed) rest
                 | None | Some (Keeper_tool_execution.Generic_deferred
                               | External_effect_deferred _) -> None))) in
      collect [] settled
    in
    match journal, execution with
    | None, (Ok _ | Error _) | Some _, Ok _ -> None
    | Some _, Error failure ->
      (match failure.Executor.cause with
       | Executor.Tool_did_not_complete node ->
         (match node.deferred_kind with
          | Some (Keeper_tool_execution.Owned_job_result_wait _ | Composition_result_wait _) ->
            collect_waiting_dependencies failure.settled
          | None | Some (Keeper_tool_execution.Generic_deferred
                        | External_effect_deferred _) -> None)
       | Executor.Run_journal_rejected _ | Plan_execution_failed _
       | Node_observation_failed _ | Outer_completion_mismatch _ -> None)
  in
  let launch_interrupted (node : Executor.node_result) =
    match node.result,Plan.contract plan node.node_id,journal with
    | Tool_result.Failed _,Some {target=Plan.Descriptor_target descriptor;_},Some worker
      when Keeper_tool_descriptor.prepared_leaf_admission descriptor
           = Keeper_tool_descriptor.Owned_job_launch_leaf ->
        (match Journal.launch_recheck worker ~node_id:node.node_id
            ~tool_name:node.tool_name ~input:node.input ~execution_id:node.execution_id ~tool_use_id:node.tool_use_id with
         | Ok (Some _) -> Some (Tool_result.message node.result)
         | Error error -> Some (Journal.error_to_string error)
         | Ok None -> None)
    | (Tool_result.Completed _ | Tool_result.Deferred _ | Tool_result.Failed _),
      (None | Some {target=(Plan.Descriptor_target _ | Plan.Child_arguments _
                          | Plan.Child_submission _ | Plan.Child_result _);_}),
      (None | Some _) -> None in
  let recovery = match execution with
    | Ok _ -> Complete_original_result
    | Error failure ->
      let cause_recovery = function
        | Executor.Tool_did_not_complete node ->
          (match node.execution_origin with
           | Executor.Dispatch_refused -> node_continuation_recovery node
           | Executor.Fresh_dispatch | Executor.Retained_completion ->
              match launch_interrupted node with
              | Some reason -> Hold_original_authority reason
              | None ->
             if List.exists (Plan.Node_id.equal node.node_id) !unavailable_results
                 || List.exists (Plan.Node_id.equal node.node_id) !accepted_children
             then Hold_original_authority (Tool_result.message node.result)
             else match continuation with
               | None -> Complete_original_result
               | Some _ ->
                 match Plan.contract plan node.node_id with
                 | None | Some {target=(Plan.Descriptor_target _ | Plan.Child_arguments _ | Plan.Child_result _);_} ->
                   Complete_original_result
                 | Some {target=Plan.Child_submission _;_} -> node_continuation_recovery node)
        | Executor.Run_journal_rejected error ->
          Hold_original_authority (Journal.error_to_string error)
        | Executor.Node_observation_failed {detail;_} -> Hold_original_authority detail
        | Executor.Plan_execution_failed _ | Executor.Outer_completion_mismatch _ ->
          Complete_original_result in
      List.fold_left (fun recovery cause -> combine_recovery recovery (cause_recovery cause))
        Complete_original_result (Executor.failure_causes failure) in
  match recovery,waiting_dependencies with
  | Hold_original_authority reason,_ ->
    on_recovery_held ~request_id ~reason;
    Keeper_msg_async.worker_interrupted ~reason
  | Complete_original_result,None -> Keeper_msg_async.worker_finished result
  | Complete_original_result,Some dependencies ->
    (match Keeper_msg_async.worker_waiting_for_dependencies ~dependencies result with
     | Ok outcome -> outcome
     | Error _ -> Keeper_msg_async.worker_finished result)


and async_submission_result
      ?skill_reference
      ?nested_calls
      ?nested_activation
      ?draft_reference
      ?run_reference
      ?composition_run_id
      ?journal
      ?continuation
      ?on_recovery_held
      ?refusal
      ?before_submit
      ?observe_submission
      ?on_producer_accepted
      ?observe_settlement
      ~plan
      ~tool_name
      ~tool_kind
      ~parent_invocation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ~turn_context
      ?clock
      ()
  =
  let turn_context = match journal with
    | None -> turn_context
    | Some journal -> original_source_context ~source:(Journal.source journal)
        ~observation:(Journal.source_observation journal) turn_context in
  let start_time = Tool_timing.start () in
  let composition_run_id = match composition_run_id with
    | Some identity -> identity
    | None -> Keeper_tool_plan.Composition_run_id.fresh () in
  let journal_worker = Atomic.make None in
  let source_task_id = match journal with
    | Some journal -> (Journal.source journal).source_task_id
    | None -> Option.bind turn_context (fun context ->
        context.Keeper_tool_call_log_context.task_id)
  in
  let request_context_fields =
    [ "composition_tool", `String tool_name
    ; "parent_tool_use_id", `String (Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation)
    ; "source_turn", `Int (Agent_core.Tool_contract.Invocation.turn parent_invocation)
    ; ( "composition_run_id"
      , `String
          (Keeper_tool_plan.Composition_run_id.to_string composition_run_id) ) ]
    @ Option.to_list
        (Option.map
           (fun reference -> "skill_reference", Skill_reference.to_yojson reference)
           skill_reference)
    @ Option.to_list (Option.map (fun reference -> "draft_reference", Tool_output.normalized_artifact_ref_to_json reference) draft_reference)
    @ Option.to_list (Option.map (fun reference -> "run_artifact", Tool_output.normalized_artifact_ref_to_json reference) run_reference)
    @ Option.to_list (Option.map (fun task_id -> "source_task_id", `String task_id)
        source_task_id)
  in
  let request_context =
    match request_context_fields with
    | [] -> None
    | fields -> Some fields
  in
  match Keeper_msg_async.server_background_switch () with
  | Error error ->
    let data =
      with_tool_kind_field tool_kind (Keeper_msg_async.submit_error_to_json error)
    in
    result_from_json
      ~tool_name
      ~start_time
      ~class_:Tool_result.Runtime_failure
      ~ok:false
      data
  | Ok background_sw ->
    let submit () = Keeper_msg_async.submit_worker_with_request_id
         ?request_context
         ~on_accepted:(fun request_id ->
           Result.bind
             (Keeper_composition_completion_outbox.prepare ~base_path:config.base_path
                ~keeper_name:meta.name ~request_id ~composition_tool:tool_name
              |> Result.map_error Keeper_composition_completion_outbox.error_to_string)
             (fun () ->
                let* () = match skill_reference,continuation,journal with
                  | None,_,_ -> Ok ()
                  | Some _,Some _,Some journal ->
                    Journal.named_binding journal |> Result.map (fun _ -> ())
                    |> Result.map_error Journal.error_to_string
                  | Some _,(None | Some _),(None | Some _) ->
                    let* binding = Keeper_composition_dependency.composition_of_request_context
                        ~request_id request_context_fields in
                    Keeper_composition_named_run.admit ~base_path:config.base_path
                      ~keeper_name:meta.name binding in
                let* () = match journal with
                | None -> Ok ()
                | Some journal ->
                  let binding = match continuation with
                    | None -> Journal.bind_request journal ~request_id
                    | Some continuation -> Journal.bind_continuation continuation ~request_id in
                  match binding with
                  | Error error -> Error (Journal.error_to_string error)
                  | Ok worker -> Atomic.set journal_worker (Some worker); Ok () in
                Option.fold ~none:(Ok ())
                  ~some:(fun accepted -> accepted request_id) on_producer_accepted))
         ~background_sw
         ~base_path:config.base_path
         ~caller:meta.name
         ~keeper_name:meta.name
         (* Without this the submitter is never told the work finished. The
            tool hands back a request id and returns, so the result reached
            the Keeper only if it remembered to read that id: measured over
            2026-08-18..26, 22 submissions produced 12 reads and a settled
            result waited a median of 21.9s against a median 2.7ms of work.
            The same callback Fusion uses, on the same broker. *)
         ~on_worker_settled:(fun settlement ->
           observe_async_run_settlement
             ~composition_tool:tool_name
             ?skill_reference
             ~composition_tool_kind:tool_kind
             ~composition_run_id
             ~parent_invocation
             ~meta
             ~turn_context
             settlement;
           Keeper_composition_completion_wake.on_worker_settled
             ~base_path:config.base_path
             ~composition_tool:tool_name
             settlement;
           Option.iter (fun observe -> observe settlement) observe_settlement)
         ~f:(fun ~request_id request_sw ->
           match journal, Atomic.get journal_worker with
           | Some _, None ->
             Keeper_msg_async.worker_finished
               (Tool_result.make_err ~tool_name ~start_time:(Tool_timing.start ())
               ~class_:Tool_result.Runtime_failure
               ~effect_disposition:Tool_result.Proven_pre_effect
               "prepared composition worker has no accepted journal binding")
           | (None | Some _), worker ->
           match refusal with
           | Some refusal ->
             let authority =
               let* worker = match worker with
                 | Some worker -> Ok worker | None -> Error "refusal completion requires its canonical journal owner" in
               let* () = Journal.validate_refusal_completion worker ~plan |> Result.map_error Journal.error_to_string in
               let* source = match journal with Some journal -> Ok (Journal.source journal)
                 | None -> Error "refusal completion has no original source" in
               let* () = validate_original_producer_activation ~config source in
               let* bound = Keeper_composition_draft.load_nested_activation ~base_path:config.base_path source
                 |> Result.map_error (fun error -> Yojson.Safe.to_string (Keeper_composition_draft.error_to_json error)) in
               let original = Keeper_composition_nested_run.create
                   ~calls:(match nested_calls with None -> [] | Some calls -> calls)
                   ~composition_run_id ~parent_invocation ~tool_name
                   ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent composition_run_id)
                   ~record_activation:None () in
               Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions original
                 ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
                   Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) bound;
               (match Keeper_composition_nested_run.check_original_admissions original
                   ~child_history:(Journal.worker_child_admission worker) with
                | Keeper_composition_nested_run.Original_admitted -> Ok ()
                | Keeper_composition_nested_run.Original_authority_held rejection ->
                    Error rejection.detail) in
             (match authority with
              | Error reason ->
                Option.iter (fun observe -> observe ~request_id ~reason) on_recovery_held;
                Keeper_msg_async.worker_interrupted ~reason
              | Ok () ->
                let data = continuation_refusal_to_json refusal in
                Keeper_msg_async.worker_finished
                  (Tool_result.make_err ~tool_name ~start_time:(Tool_timing.start ())
                    ~class_:Tool_result.Policy_rejection ~effect_disposition:Tool_result.Proven_pre_effect
                    ~data (Yojson.Safe.to_string data)))
           | None ->
           async_worker_result
             ?on_recovery_held
             ~composition_execution:Catalog.Async
             ~tool_kind
             ?skill_reference
             ?nested_calls
             ?nested_activation
             ?continuation
             ~plan
             ?journal:worker
             ~tool_name
             ~request_id
             ~composition_run_id
             ~source_invocation:parent_invocation
             ~request_sw
             ~config
             ~meta
             ~capability_authority
             ~publication_recovery
             ~ctx_snapshot
             ~turn_context
             ?clock
             ())
         () in
    let submitted =
      match Option.fold ~none:(Ok ()) ~some:(fun before -> before ()) before_submit with
      | Error result -> Error (Submission_result result)
      | Ok () ->
        let outcome = submit () in
        let observed = Option.fold ~none:(Ok ()) ~some:(fun observe -> observe outcome) observe_submission in
        (match observed with
         | Ok () -> Result.map_error (fun error -> Broker_error error) outcome
         | Error detail ->
           let original = match outcome with
             | Ok accepted -> Keeper_msg_async.submit_outcome_to_json accepted
             | Error error -> Keeper_msg_async.submit_error_to_json error in
           Error (Submission_result
             (Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
               ~effect_disposition:Tool_result.Effect_outcome_unknown
               ~data:(`Assoc ["submission_outcome_json",`String (Yojson.Safe.to_string original)])
               ("named submission observation failed: " ^ detail)))) in
    (match submitted with
     | Error (Submission_result result) -> result
     | Error (Broker_error error) ->
       let data =
         with_tool_kind_field
           tool_kind
           (Keeper_msg_async.submit_error_to_json error)
       in
       result_from_json
         ~tool_name
         ~start_time
         ~class_:Tool_result.Runtime_failure
         ~ok:false
         data
     | Ok
         ({ Keeper_msg_async.acceptance = Keeper_msg_async.Durably_accepted
          ; request_id
          } as outcome) ->
       let data =
         `Assoc
           (("composition_tool", `String tool_name)
            :: ( "composition_run_id"
               , `String
                   (Keeper_tool_plan.Composition_run_id.to_string
                      composition_run_id) )
            :: tool_kind_field tool_kind
            :: [ "execution", `String "async"
              ; "request_id", `String request_id
              ; ( "delivery"
                , `Assoc
                    [ "completion_notification", `Bool true
                    ; ( "result_reference"
                      , `Assoc
                          [ "tool", `String Catalog.status_tool_name
                          ; "arguments", `Assoc [ "request_id", `String request_id ]
                          ] )
                    ] )
              ; "submission", Keeper_msg_async.submit_outcome_to_json outcome
              ])
       in
       let binding = match skill_reference,continuation,journal with
         | None,_,_ -> Ok None
         | Some _,Some _,Some journal ->
           Journal.named_binding journal |> Result.map Option.some |> Result.map_error Journal.error_to_string
         | Some _,(None | Some _),(None | Some _) ->
           Keeper_composition_dependency.composition_of_request_context
             ~request_id request_context_fields |> Result.map Option.some in
       (match binding with
        | Ok binding ->
          let data = match data, binding with
            | `Assoc fields, Some binding -> `Assoc (fields @
                ["result_wait", Keeper_composition_dependency.composition_to_json binding])
            | _, None -> data
            | _, Some _ -> data in
          result_from_json ~tool_name ~start_time ~class_:Tool_result.Runtime_failure ~ok:true data
        | Error detail ->
          Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
            ~effect_disposition:Tool_result.Proven_post_effect ~data
            ("async request accepted but its result binding could not be encoded: " ^ detail))
     | Ok
         ({ Keeper_msg_async.acceptance =
              Keeper_msg_async.Reconciliation_required _
          ; _
          } as outcome) ->
       let data =
         `Assoc
           (("composition_tool", `String tool_name)
            :: ( "composition_run_id"
               , `String
                   (Keeper_tool_plan.Composition_run_id.to_string
                      composition_run_id) )
            :: tool_kind_field tool_kind
            :: [ "execution", `String "async"
              ; "submission", Keeper_msg_async.submit_outcome_to_json outcome
              ])
       in
       result_from_json
         ~tool_name
         ~start_time
         ~class_:Tool_result.Runtime_failure
         ~ok:false
         data)


and named_async_submission_result ~skill_reference ~plan ~tool_name ~tool_kind
    ~parent_invocation ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta)
    ~capability_authority ~publication_recovery ~ctx_snapshot ~turn_context
    ~admission ?on_child_accepted ?before_result_publication ?clock () =
  let module Draft = Keeper_composition_draft in
  let module Submission = Keeper_composition_named_submission in
  let start_time = Tool_timing.start () in
  match capability_authority with
  | Keeper_tool_runtime.Compatibility_meta ->
    Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Workflow_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect
      "named async execution requires its frozen turn capability surface"
  | Keeper_tool_runtime.Frozen_surface capability_surface ->
    let source_task_id = Option.bind turn_context (fun context ->
      context.Keeper_tool_call_log_context.task_id) in
    let original_activation () = match admission with
        | Original_child {context;_} -> Ok context
        | Fresh_named None -> Error (Submission.Invalid_request "named async submission requires its frozen activation context")
        | Fresh_named (Some context) -> Keeper_skill_activation_recorder.bind_async context
            |> Result.map_error (fun error -> Submission.Invalid_request
              (Keeper_skill_activation_recorder.error_to_string error)) in
    let make_source () =
      let* activation = original_activation () in
      let* () = match admission with
        | Original_child _ -> Ok ()
        | Fresh_named _ ->
      let* recorded = Keeper_skill_activation_recorder.record_bound_composition
          ~config activation ~invocation:parent_invocation ~tool_name skill_reference
        |> Result.map_error (fun error -> Submission.Invalid_request
          (Keeper_skill_activation_recorder.error_to_string error)) in
      (match recorded with
        | Activation_ledger.Recorded _ -> Ok ()
        | Activation_ledger.Already_recorded _ -> Error Submission.Missing_intent) in
      let* recipe = Keeper_tool_plan_request.to_yojson plan
        |> Result.map_error (fun (Keeper_tool_plan_request.Unsubstituted_param {name}) ->
          Submission.Invalid_request ("named async plan retains unbound parameter " ^ name)) in
      let* draft = Draft.prepare ~base_path:config.base_path ~capability_surface
          ~keeper_name:meta.name ~execution:Catalog.Async recipe
        |> Result.map_error (fun error -> Submission.Persistence_failed
          (Yojson.Safe.to_string (Draft.error_to_json error))) in
      let composition_run_id = Keeper_tool_plan.Composition_run_id.fresh () in
      let* run_reference = Draft.record_invocation ~base_path:config.base_path
          ?nested_activation:(match Draft.nested_calls draft with [] -> None | _::_ -> Some activation)
          ~composition_run_id
          ~invocation:parent_invocation draft
        |> Result.map_error (fun error -> Submission.Persistence_failed
          (Yojson.Safe.to_string (Draft.error_to_json error))) in
      let source : Journal.source =
        {keeper_name=meta.name;composition_run_id;draft_reference=Draft.reference draft;run_reference;
         parent_tool_use_id=Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation;
         source_turn=Agent_core.Tool_contract.Invocation.turn parent_invocation;
         source_task_id;
         producer=Journal.Named {tool_name;skill_reference;activation=Some activation;
           origin=(match admission with Fresh_named _ -> Journal.Standalone | Original_child {origin;_} -> origin)}} in
      Journal.prepare ?observation:(source_observation_of_context turn_context)
        ~base_path:config.base_path source
      |> Result.map_error (fun error -> Submission.Journal_rejected error) in
    let prepared =
      let* trace_id,physical_turn_ref,origin = match admission with
        | Fresh_named (Some context) -> Ok (meta.runtime.trace_id,
            Keeper_skill_activation_recorder.physical_turn_ref context,Journal.Standalone)
        | Original_child {context;origin;_} -> Ok (Keeper_skill_activation_recorder.bound_trace_id context,
            Keeper_skill_activation_recorder.bound_turn_ref context,origin)
        | Fresh_named None -> Error (Submission.Invalid_request "original named submission physical frame is unavailable") in
      let* request = Submission.request ~keeper_name:meta.name ~trace_id
          ~physical_turn_ref
          ~invocation:parent_invocation ~source_task_id ~origin ~skill_reference ~tool_name ~plan in
      let* intent = Submission.prepare ~base_path:config.base_path request ~make_source in
      let* child_submission = match admission with
        | Fresh_named _ -> Ok None
        | Original_child {attempt;parent_plan;_} ->
          Journal.record_child_submission attempt ~plan:parent_plan ~child_source:(Submission.source intent)
          |> Result.map Option.some |> Result.map_error (fun error -> Submission.Journal_rejected error) in
      Ok (intent,child_submission) in
    match prepared with
    | Error error -> Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown (Submission.error_to_string error)
    | Ok (intent,child_submission) ->
      let source = Submission.source intent in
      let journal = Submission.journal intent in
      let unresolved error =
        let data = match Submission.unconfirmed_request_id intent with
          | Ok None -> `Assoc []
          | Ok (Some request_id) -> `Assoc ["request_id",`String request_id]
          | Error detail -> `Assoc ["observation_error",`String (Submission.error_to_string detail)] in
        Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
          ~effect_disposition:Tool_result.Effect_outcome_unknown ~data (Submission.error_to_string error) in
      let recover () =
        let* binding = Submission.accepted intent in
        match binding with
        | None -> Ok None
        | Some binding ->
          let* () = match child_submission with
            | None -> Ok ()
            | Some submission ->
              let* accepted = Journal.accepted_child_submission submission
                |> Result.map_error (fun error -> Submission.Journal_rejected error) in
              if Yojson.Safe.equal (Keeper_composition_dependency.composition_to_json accepted)
                  (Keeper_composition_dependency.composition_to_json binding)
              then Ok () else Error Submission.Source_conflict in
          let* owner = Journal.named_result_owner journal binding
            |> Result.map_error (fun error -> Submission.Journal_rejected error) in
          (match child_submission with None -> () | Some _ ->
            Option.iter (fun accepted -> accepted ()) on_child_accepted);
          Ok (Some (Tool_result.make_ok ~tool_name ~start_time
            ~data:(`Assoc (["composition_tool",`String tool_name;
              "execution",`String "async";"request_id",`String binding.request_id;
              "result_wait",Keeper_composition_dependency.composition_to_json binding;
              "current_request",Keeper_msg_async.entry_to_json owner] @ [tool_kind_field tool_kind])) ())) in
      let permit = Atomic.make None in
      let before_submit () =
        match recover () with
        | Error error -> Error (unresolved error)
        | Ok (Some result) -> Error result
        | Ok None ->
          (match Draft.load ~base_path:config.base_path ~capability_surface ~keeper_name:meta.name
              ~sha256:source.draft_reference.sha256 with
           | Error error ->
             let class_ = match admission,error with
               | Fresh_named _,error -> Draft.failure_class error
               | Original_child _,(Draft.Capability_changed | Inputs_rejected _ | Unsupported_node _) ->
                 Tool_result.Policy_rejection
               | Original_child _,(Draft.Storage_failed _ | Draft_read_failed _ | Draft_not_found
                   | Malformed_draft _ | Plan_rejected _ | Nested_rejected _
                   | Different_keeper | Different_package | Publication_rejected _
                   | Skill_not_prepared | Nested_publication_requires_catalog) -> Tool_result.Runtime_failure in
             Error (Tool_result.make_err ~tool_name ~start_time
               ~class_ ~effect_disposition:Tool_result.Proven_pre_effect
               ~data:(Draft.error_to_json error) (Yojson.Safe.to_string (Draft.error_to_json error)))
           | Ok _ ->
             match Submission.begin_submit intent with
             | Ok ticket -> Atomic.set permit (Some ticket); Ok ()
             | Error error ->
               match recover () with
               | Ok (Some result) -> Error result
               | Ok None ->
                 (match error with
                  | Submission.Submission_in_progress ->
                    Log.Keeper.warn
                      "named submission %s: broker-entry phase is durable but admission is absent and its in-memory permit died with the original process; this occurrence stays fail-closed (Submission_in_progress) until the operator resets the intent record (docs/guides/keeper-owned-jobs.md)"
                      (Submission.path intent)
                  | Submission.Invalid_request _ | Submission.Identity_conflict
                  | Submission.Missing_intent | Submission.Unreadable_intent _
                  | Submission.Corrupt_intent _ | Submission.Source_conflict
                  | Submission.Journal_rejected _ | Submission.Stale_permit
                  | Submission.Persistence_failed _ -> ());
                 Error (unresolved error)
               | Error detail -> Error (unresolved detail)) in
      let observe_submission outcome =
        match Atomic.get permit with
        | None -> Error "named submission has no original broker-entry permit"
        | Some permit ->
          (match outcome with
           | Ok outcome -> Submission.observe_submit_outcome permit outcome
           | Error error -> Submission.observe_submit_error permit error)
          |> Result.map_error Submission.error_to_string in
      let result = match recover () with
        | Error error -> unresolved error
        | Ok (Some result) -> result
        | Ok None ->
          async_submission_result ~skill_reference ~journal ~plan
            ?on_producer_accepted:(Option.map (fun submission request_id ->
              Journal.accept_child_submission submission ~request_id
              |> Result.map (fun () -> Option.iter (fun accepted -> accepted ()) on_child_accepted)
              |> Result.map_error Journal.error_to_string) child_submission)
            ~nested_calls:[]
            ?nested_activation:(match source.producer with
              | Journal.Named {activation;_} -> activation | Journal.Prepared -> None)
            ~draft_reference:source.draft_reference ~run_reference:source.run_reference
            ~composition_run_id:source.composition_run_id ~tool_name ~tool_kind ~parent_invocation
            ~before_submit ~observe_submission ~config ~meta ~capability_authority
            ~publication_recovery ~ctx_snapshot ~turn_context ?clock () in
      let result = bind_prepared_result ~composition_run_id:source.composition_run_id
          ~run_reference:source.run_reference ~draft_reference:source.draft_reference result in
      Option.iter (fun before -> before ()) before_result_publication;
      (match Tool_bridge.attach_artifact_manifest
          ~projection:Tool_output.Inline_with_structured_diagnostic ~base_path:config.base_path result with
       | Ok result -> result
       | Error {message;_} ->
         Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
           ~effect_disposition:Tool_result.Effect_outcome_unknown
           ~data:(`Assoc ["submission_result_json",`String (Yojson.Safe.to_string (Tool_result.data result))])
           message)
;;



let resume_continuation_with ?on_recovery_held ?owner_metadata_refusal ?on_refusal_accepted ?observe_refusal_settlement
    ~capability_surface ~continuation ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) ~publication_recovery ~ctx_snapshot
    ~(turn_context : Keeper_tool_call_log_context.turn_context) ~invocation ?clock () =
  let module Draft = Keeper_composition_draft in
  let source = Journal.continuation_source continuation in
  let tool_name,skill_reference = match source.producer with
    | Journal.Prepared -> Draft.run_tool_name,None
    | Journal.Named {tool_name;skill_reference;activation=_;origin=_} -> tool_name,Some skill_reference in
  let start_time = Tool_timing.start () in
  let hold reason = Option.iter (fun observe ->
      observe ~request_id:(Journal.continuation_request_id continuation) ~reason) on_recovery_held in
  let refuse_original_draft error =
    let detail = Yojson.Safe.to_string (Draft.error_to_json error) in
    hold detail;
    Tool_result.make_err ~tool_name
      ~class_:(Draft.failure_class error) ~effect_disposition:Tool_result.Proven_pre_effect
      ~start_time ~data:(Draft.error_to_json error) detail in
  let refuse_journal error =
    hold (Journal.error_to_string error);
    Tool_result.make_err ~tool_name
      ~class_:(Journal.failure_class error) ~effect_disposition:Tool_result.Proven_pre_effect
      ~start_time ~data:(Journal.error_to_json error) (Journal.error_to_string error) in
  if meta.name <> source.keeper_name
      || publication_recovery.Keeper_publication_recovery_availability.keeper_name <> source.keeper_name
  then refuse_journal Journal.Source_conflict else
  let producer_admitted = match skill_reference with
    | None -> true
    | Some reference -> Keeper_skill_catalog.skills
        (Keeper_capability_surface.skill_projection capability_surface).catalog
        |> List.exists (fun (skill : Keeper_skill_catalog.skill) ->
          Option.exists (Skill_reference.equal reference) skill.reference &&
          match skill.surface with
          | Composition entry -> entry.execution = Catalog.Async && String.equal (Catalog.tool_name entry) tool_name
          | Instruction -> false) in
  match Draft.load_continuation_admission ~base_path:config.base_path ~capability_surface continuation with
  | Error error -> refuse_original_draft error
  | Ok admission ->
    let draft,refusal = match admission with
      | Draft.Admitted draft -> draft,None
      | Draft.Refused (draft,refusal) -> draft,Some (Current_leaf_denied refusal) in
    let nested_activation = Keeper_composition_draft.load_nested_activation ~base_path:config.base_path source in
    (match nested_activation with
    | Error error -> refuse_original_draft error
    | Ok nested_activation ->
    match Journal.continuation_readiness ~read_composition_result:Keeper_composition_dependency_result.readiness continuation with
    | Error error -> refuse_journal error
    | Ok Journal.Waiting_for_results ->
      Tool_result.make_deferred ~tool_name ~start_time
        ~data:(`Assoc ["kind",`String "waiting_for_original_results";
          "composition_run_id",`String (Keeper_tool_plan.Composition_run_id.to_string source.composition_run_id);
          "dependencies",`List (List.map Keeper_composition_dependency.to_json
            (Journal.continuation_dependencies continuation))]) ()
    | Ok Journal.Results_ready ->
      match Journal.load ~base_path:config.base_path ~keeper_name:source.keeper_name
          ~composition_run_id:source.composition_run_id with
      | Error error -> refuse_journal error
      | Ok journal ->
        let parent_invocation = Agent_core.Tool_contract.Invocation.create
            ~tool_use_id:source.parent_tool_use_id ~turn:source.source_turn
            ~schedule:(Agent_core.Tool_contract.Invocation.schedule invocation)
            ~completion:Agent_core.Tool_contract.Continue_after_success in
        let turn_context = original_source_context ~source:(Journal.source journal)
            ~observation:(Journal.source_observation journal) (Some turn_context) in
        let original_nested = Keeper_composition_nested_run.create ~calls:(Draft.nested_calls draft)
            ~composition_run_id:source.composition_run_id ~parent_invocation
            ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent source.composition_run_id)
            ~tool_name ~record_activation:None () in
        Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions original_nested
          ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
            Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) nested_activation;
        (match Keeper_composition_nested_run.check_original_admissions original_nested
          ~child_history:(fun ~node_ids -> Ok (Journal.continuation_child_admission continuation ~node_ids)) with
         | Keeper_composition_nested_run.Original_authority_held rejection ->
             hold rejection.detail;
             Tool_result.make_err ~tool_name ~start_time
             ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
             ~data:rejection.data rejection.detail
         | Keeper_composition_nested_run.Original_admitted ->
           let refusal = match owner_metadata_refusal,refusal,skill_reference with
             | Some metadata_refusal,_,_ when Draft.nested_calls draft = [] ->
               Some (Original_owner_metadata_refused metadata_refusal)
             | (None | Some _),Some refusal,(None | Some _) -> Some refusal
             | None,None,Some reference when not producer_admitted && Draft.nested_calls draft = [] ->
               if Keeper_capability_surface.changed_skill_proven capability_surface reference then
                 Some (Original_producer_changed reference)
               else if Keeper_capability_surface.exact_skill_absence_proven capability_surface reference then
                 Some (Original_producer_absent reference)
               else None
             | (None | Some _),None,(None | Some _) -> None in
           if (Option.is_some owner_metadata_refusal || not producer_admitted) && Option.is_none refusal then
             refuse_journal Journal.Source_conflict
           else match (match refusal with None -> Ok () | Some _ -> validate_original_producer_activation ~config source) with
           | Error detail ->
               hold detail;
               Tool_result.make_err ~tool_name ~start_time ~class_:Tool_result.Runtime_failure
               ~effect_disposition:Tool_result.Proven_pre_effect detail
           | Ok () ->
           let on_producer_accepted,observe_settlement = match refusal with
             | None -> None,None
             | Some _ -> on_refusal_accepted,observe_refusal_settlement in
           async_submission_result ?on_recovery_held ?skill_reference ~journal ~continuation ?refusal
          ?on_producer_accepted ?observe_settlement
          ~nested_calls:(Draft.nested_calls draft) ?nested_activation
          ~draft_reference:source.draft_reference ~run_reference:source.run_reference
          ~composition_run_id:source.composition_run_id ~plan:(Draft.plan draft)
          ~tool_name ~tool_kind:Keeper_tool_descriptor.Async_composition_tool
          ~parent_invocation ~config ~meta
          ~capability_authority:(Keeper_tool_runtime.Frozen_surface capability_surface)
          ~publication_recovery ~ctx_snapshot ~turn_context ?clock ()
        |> bind_prepared_result ~composition_run_id:source.composition_run_id
            ~run_reference:source.run_reference ~draft_reference:source.draft_reference
        )
    )
;;

let resume_continuation ?on_recovery_held ?owner_metadata_refusal ~capability_surface ~continuation ~config ~meta
    ~publication_recovery ~ctx_snapshot ~turn_context ~invocation ?clock () =
  resume_continuation_with ?on_recovery_held ?owner_metadata_refusal ~capability_surface ~continuation ~config ~meta
    ~publication_recovery ~ctx_snapshot ~turn_context ~invocation ?clock ()
;;

module For_testing = struct
  type nonrec recovery_decision = continuation_recovery =
    | Complete_original_result
    | Hold_original_authority of string
  let continuation_recovery_of_result = continuation_recovery_of_result
  let combine_recovery = combine_recovery
  let resume_continuation ?owner_metadata_refusal ~after_refusal_binding ~after_refusal_settled
      ~capability_surface ~continuation ~config ~meta ~publication_recovery
      ~ctx_snapshot ~turn_context ~invocation ?clock () =
    resume_continuation_with ?owner_metadata_refusal
      ~on_refusal_accepted:(fun request_id -> after_refusal_binding ~request_id; Ok ())
      ~observe_refusal_settlement:(fun _settlement -> after_refusal_settled ())
      ~capability_surface ~continuation ~config ~meta ~publication_recovery
      ~ctx_snapshot ~turn_context ~invocation ?clock ()

  let async_worker_result = async_worker_result
  let node_result_to_json = node_result_to_json
  let project_execution_result = project_execution_result
  let result_of_execution = result_of_execution
  let observe_node_result = observe_node_result
  let failure_payload = failure_payload
  let instruction_skill_description = instruction_skill_description
  let make_instruction_skill_tool = make_instruction_skill_tool
  let status_result = status_result
  let cancel_result = cancel_result
end


let make_tools_with_authority
      ?(instruction_skills : instruction_skill list = [])
      ?(skill_compositions : composition_skill list = [])
      ?composition_plan_index
      ?record_instruction_activation
      ?record_composition_activation
      ?record_nested_composition_activation
      ?nested_activation_context
      ?result_delivery
      ~(config : Workspace.config)
      ~meta
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ?turn_sandbox_factory
      ?turn_ctx_cell
      ?clock
      ?continuation_channel
      ?gate_context
      ?gate_causal_context
      ?gate_grant
      ?record_gate_result
      ?on_completed
      ?on_deferred
      ?on_external_effect_deferred
      ?on_failed
      ?on_externalization_error
      ~descriptors
      ()
  =
  (* Skill-declared entries went through the same [Catalog.parse] as the
     TOML catalog, so materialization cannot tell them apart — one closure
     serves both. Name collisions across the two sources are refused where
     both catalogs are loaded, before this point. *)
  let composition_tools =
    skill_compositions
    |> List.map (fun (skill : composition_skill) ->
    let entry = skill.entry in
    let tool_name = Catalog.tool_name entry in
    (* The approval policy cannot look this tool up: it is an Agent-Core tool,
       not a keeper descriptor, so a descriptor lookup finds nothing and the
       policy asks. Declaring the plan's node tools here lets it judge the
       composition by what the composition runs. Written once per turn, at the
       one point that already holds the plan. *)
    Option.iter
      (fun index ->
        Keeper_tool_composition_plan_index.record
          index
          ~composition:tool_name
          ~node_tools:
            (List.map
               (fun (node : Keeper_tool_plan.node) ->
                  node.Keeper_tool_plan.tool_name)
               (Keeper_tool_plan.nodes entry.plan)))
      composition_plan_index;
    let completion = Executor.outer_completion entry.plan in
    (* A template is not the input a node will execute. Only static read-only
       contracts for every node prove the whole inline composition read-only.
       Async admission writes a durable request even when its nodes only read. *)
    let read_only =
      List.for_all (fun (node : Keeper_tool_plan.node) ->
        match Keeper_tool_plan.descriptor entry.plan node.id with
        | None -> false
        | Some descriptor ->
          Keeper_tool_descriptor.readonly_static_hint descriptor = Some true)
        (Keeper_tool_plan.nodes entry.plan)
    in
    (* A read-only leaf can still own a serial resource, such as a browser
       session. Only leaves whose own contract permits concurrent execution
       can prove that separate invocations of this whole plan may overlap. *)
    let causal_context_isolatable = match gate_causal_context, gate_context with
      | Some _, _ | None, None -> true
      | None, Some _ -> false
    in
    let concurrent = read_only && causal_context_isolatable
      && List.for_all (fun (node : Keeper_tool_plan.node) ->
        match Keeper_tool_plan.descriptor entry.plan node.id with
        | Some { Keeper_tool_descriptor.execution =
                   Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Concurrent; _ } -> true
        | Some { Keeper_tool_descriptor.execution =
                   ( Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial
                   | Keeper_tool_descriptor.Terminal ); _ }
        | None -> false) (Keeper_tool_plan.nodes entry.plan)
    in
    let call_effect _ =
      match entry.execution with
      | Catalog.Async -> Agent_core.Tool.Effect_possible
      | Catalog.Inline ->
        if read_only
        then Agent_core.Tool.Read_only
        else Agent_core.Tool.Effect_possible
    in
    let descriptor =
      match entry.execution, completion with
      | Catalog.Async, Agent_core.Tool_contract.Continue_after_success ->
        Agent_core.Tool.ordinary_descriptor ~call_effect Agent_core.Tool_contract.Serial
      | Catalog.Inline, Agent_core.Tool_contract.Continue_after_success ->
        Agent_core.Tool.ordinary_descriptor ~call_effect
          (if concurrent then Agent_core.Tool_contract.Concurrent else Agent_core.Tool_contract.Serial)
      | Catalog.Inline, Agent_core.Tool_contract.Terminal_after_success disposition ->
        Agent_core.Tool.terminal_descriptor disposition
      | Catalog.Async, Agent_core.Tool_contract.Terminal_after_success _ ->
        invalid_arg "validated async composition retained a terminal completion"
    in
    let tool_externalization_error =
      match entry.execution with
      | Catalog.Async -> None
      | Catalog.Inline -> on_externalization_error
    in
    (* Paired here, where the entry is in hand: a composition declares
       [defer_loading] in its Skill block, and nothing downstream should have
       to find that block again by the generated tool name. *)
    let model_projection = Tool_output.default_model_projection in
    let make_tool ?prepared_files () = Tool_bridge.agent_core_tool_of_masc_with_execution_env
      ~descriptor
      ~base_path:config.base_path
      ~model_projection:(fun () -> model_projection)
      ?on_externalization_error:tool_externalization_error
      ~name:tool_name
      ~description:(entry_description entry)
      ~input_schema:(Catalog.input_schema_of_params entry.params)
      (fun execution_env input ->
        let start_time = Tool_timing.start () in
        match
          Tool_input_validation.validate_args
            ~schema:(Catalog.input_schema_of_params entry.params)
            ~name:tool_name
            ~args:input
            ()
        with
        | Error rejection -> rejection
        | Ok _ ->
          (match Agent_core.Tool.Execution_env.invocation execution_env with
           | None ->
             Tool_result.runtime_err
               ~tool_name
               ~start_time
               "composition execution requires Agent-Core invocation identity"
           | Some parent_invocation ->
             let gate_context, record_gate_result =
               if (concurrent || Option.is_some prepared_files) && entry.execution = Catalog.Inline
               then isolate_gate_context ~gate_causal_context ~gate_context ~record_gate_result
               else gate_context, record_gate_result
             in
             let turn_context =
               match prepared_files with
               | Some prepared -> Some (Keeper_prepared_inline_files.source prepared)
               | None -> Option.map
                 (fun cell ->
                    Keeper_tool_call_log_context.get_turn_context_record
                      ~cell
                      ())
                 turn_ctx_cell
             in
             (match entry.execution with
              | Catalog.Async ->
                (match
                   Catalog.instantiate
                     ~descriptors
                     ~args:input
                     entry
                 with
                 | Error error ->
                   let message = Catalog.instantiation_error_to_string error in
                   let class_ =
                     match error with
                     | Catalog.Missing_argument _
                     | Catalog.Instantiated_plan_rejected _ ->
                       Tool_result.Policy_rejection
                   in
                   let data =
                     `Assoc
                       [ "composition_tool", `String tool_name
                       ; tool_kind_field (Catalog.tool_kind entry)
                       ; "error", Catalog.instantiation_error_to_json error
                       ]
                   in
                   Tool_result.make_err
                     ~tool_name
                     ~class_
                     ~start_time
                     ~data
                     ~metadata:data
                     message
                 | Ok plan ->
                   named_async_submission_result
                     ~admission:(Fresh_named nested_activation_context)
                     ~skill_reference:skill.reference ~plan ~tool_name
                     ~tool_kind:(Catalog.tool_kind entry) ~parent_invocation
                     ~config ~meta ~capability_authority ~publication_recovery
                     ~ctx_snapshot ~turn_context ?clock ())
              | Catalog.Inline ->
                (match
                   (match prepared_files with
                    | Some prepared -> Ok (Keeper_prepared_inline_files.plan prepared)
                    | None -> Catalog.instantiate ~descriptors ~args:input entry)
                 with
                 | Error error ->
                   (* Unreachable through the validated schema — required
                      params are enforced there — but total: a rejected
                      binding names the argument instead of executing a
                      half-bound plan. *)
                   let message = Catalog.instantiation_error_to_string error in
                   let class_ =
                     match error with
                     | Catalog.Missing_argument _
                     | Catalog.Instantiated_plan_rejected _ ->
                       Tool_result.Policy_rejection
                   in
                   let data =
                     `Assoc
                       [ "composition_tool", `String tool_name
                       ; tool_kind_field (Catalog.tool_kind entry)
                       ; "error", Catalog.instantiation_error_to_json error
                       ]
                   in
                   Tool_result.make_err
                     ~tool_name
                     ~class_
                     ~start_time
                     ~data
                     ~metadata:data
                     message
                 | Ok plan ->
             let activation =
               match record_composition_activation with
               | None -> Ok ()
               | Some record ->
                 (match
                    record
                      ~invocation:parent_invocation
                      ~tool_name
                      ~reference:skill.reference
                  with
                  | Error error -> Error error
                  | Ok
                      ( Activation_ledger.Recorded _
                      | Activation_ledger.Already_recorded _ ) ->
                    Ok ())
             in
             (match activation with
              | Error error -> activation_failure ~tool_name ~start_time error
              | Ok () ->
             let run_id = Keeper_tool_plan.Run_id.fresh () in
             let composition_run_id = Keeper_tool_plan.Composition_run_id.fresh () in
             let committed_receipts = ref [] in
             let execution =
               with_ready_inline_files ~config ~meta ~source:turn_context ~plan
                 ~prepared_files ~gate_causal_context ~gate_context ~record_gate_result
                 (fun ready_files gate_context record_gate_result ->
               execute_keeper_plan
                 ~capability_authority
                 ~plan
                 ~run_id
                 ~composition_run_id
                 ~parent_invocation
                 ~config
                 ~meta
                 ~publication_recovery
                 ~ctx_snapshot
                 ~keeper_turn_id:(keeper_turn_id_of turn_context)
                 ?source_context:turn_context
                 ?prepared_files
                 ?ready_files
                 ?turn_sandbox_factory
                 ?clock
                 ?continuation_channel
                 ?gate_context
                 ?gate_grant
                 ?record_gate_result
                 ?on_completed:
                   (Option.map
                      (fun completed -> completed ~composition_tool:tool_name)
                      on_completed)
                 ?on_deferred
                 ?on_external_effect_deferred
                 ?on_failed
                 ?observe_node_result:
                   (Option.map
                      (fun turn_context ->
                         observe_node_result
                           ~on_receipt_committed:(fun execution_id ->
                             committed_receipts := execution_id :: !committed_receipts)
                           ~composition_tool:tool_name
                           ~composition_execution:entry.execution
                           ~composition_tool_kind:(Catalog.tool_kind entry)
                           ~composition_run_id
                           ~parent_invocation
                           ~meta
                           ~turn_context)
                      turn_context)
                 ())
             in
             (match execution with
              | Error
                  ({ Executor.effect_disposition =
                       ( Tool_result.Proven_post_effect
                       | Tool_result.Effect_outcome_unknown )
                   ; _
                   } as failure) ->
                (* The aggregate is computed from every settled sibling and all
                   earlier batches, so a selected Deferred cause cannot hide an
                   earlier committed write or a sibling's unknown/post-effect
                   failure.  It fences the turn unless every failed node's own
                   boundary sends the failure back to the model
                   ([failure_returns_to_model]).  Composition execution has no
                   persisted cursor, so only an entirely proven-pre-effect
                   defer may remain resumable. *)
                if not (failure_returns_to_model ~plan ~committed:!committed_receipts failure) then
                (match composition_cause failure with
                 | Pre_effect_only { expected; actual } ->
                   (* This branch is post-effect or unknown, and a completion
                      mismatch is settled [Proven_pre_effect] before any node
                      runs, so the two cannot meet. If they ever do, an effect
                      may have happened and there is no cause to terminalize
                      it with; stop loudly rather than let the turn continue
                      past an unfenced effect. *)
                   invalid_arg
                     (Printf.sprintf
                        "composition %s settled a completion mismatch (plan %s, call \
                         %s) with effect_disposition=%s"
                        tool_name
                        (Yojson.Safe.to_string
                           (Agent_core.Tool_contract.completion_to_yojson expected))
                        (Yojson.Safe.to_string
                           (Agent_core.Tool_contract.completion_to_yojson actual))
                        (Tool_result.failure_effect_disposition_to_string
                           failure.effect_disposition))
                 | Terminal_cause cause ->
                   Option.iter
                     (fun mark_failed ->
                        mark_failed
                          { Keeper_tools_agent_core.failure_class =
                              failure_class failure
                          ; effect_disposition = failure.effect_disposition
                          ; detail =
                              Keeper_terminal_effect_detail.Composition_failed
                                { composition_tool = tool_name
                                ; cause
                                ; payload =
                                    failure_data
                                      ~tool_name
                                      ~tool_kind:(Catalog.tool_kind entry)
                                      failure
                                }
                          })
                     on_failed)
              | Ok _
              | Error
                  { Executor.effect_disposition = Tool_result.Proven_pre_effect
                  ; _
                  } ->
                ());
             let executor_result =
               result_of_execution
                 ~tool_name
                 ~tool_kind:(Catalog.tool_kind entry)
                 ~start_time
                 execution
             in
             let result =
               match
                 project_execution_result
                   ~base_path:config.base_path ~plan ~execution executor_result
               with
               | Ok result -> result
               | Error { message; _ } ->
                 Option.iter
                   (fun mark_failed ->
                      mark_failed
                        { Keeper_tools_agent_core.failure_class =
                            Tool_result.Runtime_failure
                        ; effect_disposition = Tool_result.Effect_outcome_unknown
                        ; detail =
                            Keeper_terminal_effect_detail.Composition_result_manifest_unpersisted
                              { composition_tool = tool_name; detail = message }
                        })
                   on_failed;
                 Tool_result.make_err
                   ~tool_name
                   ~class_:Tool_result.Runtime_failure
                   ~start_time
                   message
             in
             record_skill_composition_evidence
               ~on_publication_failure:(fun detail ->
                 match execution with
                 | Error failure when failure_returns_to_model ~plan ~committed:!committed_receipts failure ->
                   (* Unpublished evidence fences the turn because the record of
                      what already took effect is what lets the turn go on. A
                      refusal that took no effect has nothing to record, and the
                      native loop ends the turn on any terminal-effect failure
                      (Keeper_tool_terminal_boundary), so fencing here would end
                      a turn over a file that describes nothing. *)
                   (match failure.effect_disposition with
                    | Tool_result.Proven_pre_effect -> ()
                    | Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown ->
                      Option.iter (fun mark_failed -> mark_failed
                        { Keeper_tools_agent_core.failure_class = Tool_result.Runtime_failure;
                          effect_disposition = failure.effect_disposition;
                          detail =
                            Keeper_terminal_effect_detail.Composition_evidence_unpublished
                              { composition_tool = tool_name; detail } }) on_failed)
                 | Ok _ | Error _ -> ())
               ~config
               ~reference:skill.reference
               ~composition_run_id
               ~request_id:None
               ~parent_invocation
               ~meta
               ~composition_tool:tool_name
               ~composition_execution:Catalog.Inline
               ~execution
               ~result;
             observe_composition_run_summary
               ~composition_tool:tool_name
               ~skill_reference:skill.reference
               ~composition_execution:Catalog.Inline
               ~composition_tool_kind:(Catalog.tool_kind entry)
               ~composition_run_id
               ~parent_invocation
               ~meta
               ~turn_context
               ~input
               ~output_text:(Tool_result.message result)
               ~success:(Tool_result.is_success result)
               ~duration_ms:(Tool_result.duration_ms result)
               ~typed_result:result
               ();
             result)))))
    in
    let ordinary = make_tool () in
    let resource_candidate =
      match capability_authority, entry.execution, completion with
      | Keeper_tool_runtime.Frozen_surface _, Catalog.Inline,
        Agent_core.Tool_contract.Continue_after_success ->
        causal_context_isolatable && Keeper_prepared_inline_files.eligible entry.plan
      | Keeper_tool_runtime.Compatibility_meta, _, _
      | _, Catalog.Async, _
      | _, _, Agent_core.Tool_contract.Terminal_after_success _ -> false
    in
    let tool = if not resource_candidate then ordinary else
      let prepare ~sw input =
        let source = Option.map (fun cell ->
          Keeper_tool_call_log_context.get_turn_context_record ~cell ()) turn_ctx_cell in
        match Catalog.instantiate ~descriptors ~args:input entry with
        | Error _ -> Ok None
        | Ok plan ->
          match Keeper_prepared_inline_files.prepare ~sw ~config ~meta ~source plan with
          | None -> Ok None
          | Some prepared_files ->
            match Keeper_prepared_inline_files.scopes prepared_files with
            | [] -> invalid_arg "prepared Inline file plan has no file footprint"
            | scope :: additional_scopes ->
              let prepared = make_tool ~prepared_files () in
              Ok (Some (Agent_core.Tool.scoped_call ~scope ~additional_scopes prepared.handler))
      in
      Agent_core.Tool.of_schema
        ~descriptor:(Agent_core.Tool.ordinary_descriptor_scoped
          ~call_effect:(Agent_core.Tool.call_effect ordinary) ~prepare)
        ordinary.schema ordinary.handler
    in
    ( tool
    , entry.Catalog.loading
    , model_projection ))
  in
  let draft_tools =
    match capability_authority with
    | Keeper_tool_runtime.Compatibility_meta -> []
    | Keeper_tool_runtime.Frozen_surface capability_surface ->
      let module Draft = Keeper_composition_draft in
      let rejection ~tool_name ~start_time error =
        let class_ = Draft.failure_class error in
        let data = Draft.error_to_json error in
        Tool_result.make_err ~tool_name ~class_ ~effect_disposition:Tool_result.Proven_pre_effect
          ~start_time ~data (Yojson.Safe.to_string data)
      in
      let journal_rejection ~start_time error =
        Tool_result.make_err ~tool_name:Draft.run_tool_name
          ~class_:(Journal.failure_class error)
          ~effect_disposition:Tool_result.Effect_outcome_unknown
          ~start_time ~data:(Journal.error_to_json error)
          (Journal.error_to_string error)
      in
      let make (schema : Masc_domain.tool_schema) ~artifact_projection ~call_effect handle =
        let model_projection = Tool_output.default_model_projection in
        (Tool_bridge.agent_core_tool_of_masc_with_execution_env
           ~descriptor:(Agent_core.Tool.ordinary_descriptor ~call_effect Agent_core.Tool_contract.Serial)
           ~base_path:config.base_path ~model_projection:(fun () -> model_projection)
           ?on_externalization_error ~name:schema.name ~description:schema.description
           ~input_schema:schema.input_schema
           (fun execution_env input ->
              let start_time = Tool_timing.start () in
              match Tool_input_validation.validate_args ~schema:schema.input_schema
                      ~name:schema.name ~args:input () with
              | Error rejected -> rejected
              | Ok _ ->
                let result = handle ~start_time execution_env input in
                match Tool_bridge.attach_artifact_manifest
                        ~projection:artifact_projection ~base_path:config.base_path result with
                | Ok result -> result
                | Error { message; _ } ->
                  Tool_result.make_err ~tool_name:schema.name ~class_:Tool_result.Runtime_failure
                    ~effect_disposition:Tool_result.Effect_outcome_unknown ~start_time message)
        , Tool_loading_declarations.loading_of_tool schema.name
        , model_projection)
      in
      let prepare = make Draft.prepare_schema ~artifact_projection:Tool_output.Inline_with_reference
        ~call_effect:(fun _ -> Agent_core.Tool.Read_only)
        (fun ~start_time _execution_env input ->
          match Draft.prepare_request ~base_path:config.base_path ~capability_surface ~keeper_name:meta.name input with
          | Error error -> rejection ~tool_name:Draft.prepare_tool_name ~start_time error
          | Ok draft ->
            Tool_result.make_ok ~tool_name:Draft.prepare_tool_name ~start_time ~data:(Keeper_composition_draft_preview.preview draft) ()
            |> Tool_result.with_retained_artifacts [ Draft.reference draft ]) in
      let run = make Draft.run_schema ~artifact_projection:Tool_output.Inline_with_structured_diagnostic
        ~call_effect:(fun _ -> Agent_core.Tool.Effect_possible)
        (fun ~start_time execution_env input ->
          match Agent_core.Tool.Execution_env.invocation execution_env with
          | None -> Tool_result.runtime_err ~tool_name:Draft.run_tool_name ~start_time
              "composition run requires Agent-Core invocation identity"
          | Some parent_invocation ->
            match Draft.resolve_run_request ~base_path:config.base_path ~capability_surface ~keeper_name:meta.name input with
            | Error error -> rejection ~tool_name:Draft.run_tool_name ~start_time error
            | Ok draft ->
              let plan = Draft.plan draft in
              let turn_context = Option.map (fun cell ->
                Keeper_tool_call_log_context.get_turn_context_record ~cell ()) turn_ctx_cell in
              let bind_result ~composition_run_id ~run_reference result =
                bind_prepared_result ~composition_run_id ~run_reference
                  ~draft_reference:(Draft.reference draft) result in
              let execute_run ?journal ?continuation ~nested_activation ~composition_run_id ~run_reference ~parent_invocation ~turn_context () =
                let result = match Draft.execution draft with
                  | Catalog.Async ->
                    async_submission_result ?journal ?continuation ~draft_reference:(Draft.reference draft) ~run_reference ~composition_run_id
                      ~nested_calls:(Draft.nested_calls draft) ?nested_activation
                      ~plan ~tool_name:Draft.run_tool_name ~tool_kind:Keeper_tool_descriptor.Async_composition_tool
                      ~parent_invocation ~config ~meta ~capability_authority ~publication_recovery
                      ~ctx_snapshot ~turn_context ?clock ()
                  | Catalog.Inline ->
                    with_ready_inline_files ~config ~meta ~source:turn_context ~plan
                      ~prepared_files:None ~gate_causal_context ~gate_context ~record_gate_result
                      (fun ready_files gate_context record_gate_result ->
                    let nested_run = Keeper_composition_nested_run.create
                        ~calls:(Draft.nested_calls draft) ~composition_run_id ~parent_invocation
                        ~tool_name:Draft.run_tool_name ~record_activation:record_nested_composition_activation () in
                    let execution = execute_keeper_plan ~capability_authority ~plan ~composition_run_id
                        ~run_id:(Keeper_tool_plan.Run_id.fresh ()) ~parent_invocation ~config ~meta
                        ~publication_recovery ~ctx_snapshot ~keeper_turn_id:(keeper_turn_id_of turn_context)
                        ?source_context:turn_context ?ready_files
                        ?turn_sandbox_factory ?clock ?continuation_channel ?gate_context ?gate_grant ?record_gate_result
                        ?on_deferred ?on_external_effect_deferred
                        ~admit_node:(Keeper_composition_nested_run.admit_node nested_run)
                        ?observe_node_result:(Option.map (fun turn_context ->
                          observe_node_result ?on_receipt_committed:None
                            ~composition_tool:Draft.run_tool_name ~composition_execution:Catalog.Inline
                            ~composition_tool_kind:Keeper_tool_descriptor.Composition_tool ~composition_run_id
                            ~parent_invocation ~meta ~turn_context) turn_context) () in
                    let result = result_of_execution ~tool_name:Draft.run_tool_name
                        ~tool_kind:Keeper_tool_descriptor.Composition_tool ~start_time execution in
                    let nested_scopes = match Draft.nested_calls draft with [] -> None | _ :: _ ->
                      Some (Keeper_composition_nested_run.evidence_to_json nested_run ~plan ~execution) in
                    let result = match Keeper_composition_result.project ?nested_scopes ~base_path:config.base_path ~plan ~execution result with
                      | Ok result -> result
                      | Error { message; _ } -> Tool_result.make_err ~tool_name:Draft.run_tool_name
                          ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Effect_outcome_unknown
                          ~start_time message in
                    observe_composition_run_summary
                      ~composition_tool:Draft.run_tool_name ~composition_execution:Catalog.Inline
                      ~composition_tool_kind:Keeper_tool_descriptor.Composition_tool ~composition_run_id
                      ~parent_invocation ~meta ~turn_context ~input ~output_text:(Tool_result.message result)
                      ~success:(Tool_result.is_success result) ~duration_ms:(Tool_result.duration_ms result)
                      ~typed_result:result ();
                    result)
                in
                bind_result ~composition_run_id ~run_reference result
              in
              let resume_run_id = match input with
                | `Assoc fields -> List.assoc_opt "resume_run_id" fields
                | _ -> None in
              match resume_run_id, Draft.execution draft with
              | Some _, Catalog.Inline ->
                rejection ~tool_name:Draft.run_tool_name ~start_time
                  (Draft.Malformed_draft "resume_run_id requires a prepared async draft")
              | Some (`String identity), Catalog.Async ->
                (match Keeper_tool_plan.Composition_run_id.of_string identity with
                 | Error _ -> rejection ~tool_name:Draft.run_tool_name ~start_time
                     (Draft.Malformed_draft "resume_run_id must be a composition run UUIDv7")
                 | Ok composition_run_id ->
                   match Journal.load ~base_path:config.base_path ~keeper_name:meta.name ~composition_run_id with
                   | Error error -> journal_rejection ~start_time error
                   | Ok journal ->
                     let source = Journal.source journal in
                     if (match source.producer with Journal.Named _ -> true | Prepared -> false) then
                       journal_rejection ~start_time Journal.Source_conflict
                     else if not (Yojson.Safe.equal
                       (Tool_output.normalized_artifact_ref_to_json source.draft_reference)
                       (Tool_output.normalized_artifact_ref_to_json (Draft.reference draft))) then
                       journal_rejection ~start_time Journal.Source_conflict
                     else
                       let parent_invocation = Agent_core.Tool_contract.Invocation.create
                         ~tool_use_id:source.parent_tool_use_id ~turn:source.source_turn
                         ~schedule:(Agent_core.Tool_contract.Invocation.schedule parent_invocation)
                         ~completion:Agent_core.Tool_contract.Continue_after_success in
                       (* The new physical turn keeps its own trace/session identity,
                          while work and completion belong to the original task. *)
                       let context = match turn_context with
                         | Some context -> context
                         | None -> Keeper_tool_call_log_context.get_turn_context_record
                             ~cell:(Keeper_tool_call_log_context.create_cell ()) () in
                       let turn_context = Some { context with task_id = source.source_task_id } in
                       match Journal.waiting_continuation journal with
                       | Error error -> journal_rejection ~start_time error
                       | Ok continuation ->
                         (match Draft.load_nested_activation ~base_path:config.base_path source with
                          | Error error -> rejection ~tool_name:Draft.run_tool_name ~start_time error
                          | Ok nested_activation ->
                            let original_nested = Keeper_composition_nested_run.create ~calls:(Draft.nested_calls draft)
                                ~composition_run_id ~parent_invocation
                                ~delivery_parent_tool_use_id:(Keeper_composition_nested_run.async_result_parent composition_run_id)
                                ~tool_name:Draft.run_tool_name ~record_activation:None () in
                            Option.iter (fun bound -> Keeper_composition_nested_run.restore_admissions original_nested
                              ~find_activation:(fun ~invocation ~tool_name ~scope ~reference ->
                                Keeper_skill_activation_recorder.find_bound_nested ~config bound ~invocation ~tool_name ~scope ~reference)) nested_activation;
                            match Keeper_composition_nested_run.check_original_admissions original_nested
                                ~child_history:(Journal.child_admission journal) with
                            | Keeper_composition_nested_run.Original_authority_held error -> Tool_result.make_err ~tool_name:Draft.run_tool_name ~start_time
                                ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect
                                ~data:error.data error.detail
                            | Keeper_composition_nested_run.Original_admitted -> execute_run ~journal ?continuation ~nested_activation ~composition_run_id ~run_reference:source.run_reference
                                ~parent_invocation ~turn_context ()))
              | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _), Catalog.Async ->
                rejection ~tool_name:Draft.run_tool_name ~start_time
                  (Draft.Malformed_draft "resume_run_id must be a string")
              | None, (Catalog.Inline | Catalog.Async) ->
                let nested_activation = match Draft.execution draft,Draft.nested_calls draft with
                  | Catalog.Inline,_ | Catalog.Async,[] -> Ok None
                  | Catalog.Async,_::_ ->
                    (match nested_activation_context with
                     | None -> Error Keeper_skill_activation_recorder.Runtime_attempt_missing
                     | Some context -> Keeper_skill_activation_recorder.bind_async context |> Result.map Option.some) in
                (match nested_activation with
                 | Error error -> Tool_result.make_err ~tool_name:Draft.run_tool_name
                     ~class_:Tool_result.Runtime_failure ~effect_disposition:Tool_result.Proven_pre_effect ~start_time
                     ~data:(Keeper_skill_activation_recorder.error_to_yojson error)
                     (Keeper_skill_activation_recorder.error_to_string error)
                 | Ok nested_activation ->
                let composition_run_id = Keeper_tool_plan.Composition_run_id.fresh () in
                match Draft.record_invocation ~base_path:config.base_path ?nested_activation ~composition_run_id
                        ~invocation:parent_invocation draft with
                | Error error -> rejection ~tool_name:Draft.run_tool_name ~start_time error
                | Ok run_reference ->
                  match Draft.execution draft with
                  | Catalog.Inline -> execute_run ~nested_activation ~composition_run_id ~run_reference ~parent_invocation ~turn_context ()
                  | Catalog.Async ->
                    let source : Journal.source =
                      { keeper_name = meta.name; composition_run_id
                      ; draft_reference = Draft.reference draft; run_reference
                      ; parent_tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id parent_invocation
                      ; source_turn = Agent_core.Tool_contract.Invocation.turn parent_invocation
                      ; source_task_id = Option.bind turn_context (fun context -> context.Keeper_tool_call_log_context.task_id); producer=Journal.Prepared } in
                    match Journal.prepare ?observation:(source_observation_of_context turn_context)
                        ~base_path:config.base_path source with
                    | Error error -> bind_result ~composition_run_id ~run_reference (journal_rejection ~start_time error)
                    | Ok journal -> execute_run ~journal ~nested_activation ~composition_run_id ~run_reference ~parent_invocation ~turn_context ()))
      in
      [ prepare; run ]
  in
  let composition_tools = composition_tools @ draft_tools in
  (* A keeper with no instruction skills gets no tool: an empty [Available]
     list would ask the model to reach for something that answers nothing. *)
  let composition_tools =
    match instruction_skills with
    | [] -> composition_tools
    | skills ->
      composition_tools
      @ [ ( make_instruction_skill_tool
            ~config
            ?record_activation:record_instruction_activation
            ~assess_applicability:(fun ~reference ~body ->
              let context = Option.map (fun capture -> (capture ()).Keeper_gate.snapshot) gate_context in
              Typesafeai_skill_applicability.assess ?clock ~keeper_id:meta.name
                ~context ~reference ~body ())
            ~instruction_skills:skills
            ()
          , Tool_loading_declarations.loading_of_tool Catalog.skill_tool_name
          , Tool_output.bounded_inline_model_projection )
        ]
  in
  (* Built only where they can address something: an async entry on this
     surface is the one thing that mints the request id they take. *)
  let async_controls =
    draft_tools <> [] || Catalog.requires_async_controls
      (List.map (fun (skill : composition_skill) -> skill.entry) skill_compositions)
  in
  let status_tool =
      make_request_control_tool
        ~config
        ~name:Catalog.status_tool_name
        ~description:Tool_schemas_composition_control.status_schema.description
        ~input_schema:Tool_schemas_composition_control.status_schema.input_schema
        ~descriptor:
          (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
        ~on_rejected:(fun execution_env -> discard_status_binding ~delivery_registry:result_delivery
          ~invocation:(Agent_core.Tool.Execution_env.invocation execution_env))
        ~handle:(fun execution_env request_id ->
          status_result_for_invocation ?delivery_registry:result_delivery
            ?invocation:(Agent_core.Tool.Execution_env.invocation execution_env)
            ~config ~meta ~request_id ())
  in
  let cancel_tool =
      make_request_control_tool
        ~config
        ~name:Catalog.cancel_tool_name
        ~description:Tool_schemas_composition_control.cancel_schema.description
        ~input_schema:Tool_schemas_composition_control.cancel_schema.input_schema
        ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Serial)
        ~on_rejected:(fun _execution_env -> ())
        ~handle:(fun _execution_env request_id -> cancel_result ~config ~meta ~request_id)
  in
  (* The Skill reader and the two request controls are not Skill
     compositions; each is declared in its own [config/tools/<name>.toml]. *)
  if async_controls
  then
    composition_tools
    @ [ ( status_tool
        , Tool_loading_declarations.loading_of_tool Catalog.status_tool_name
        , Tool_output.default_model_projection )
      ; ( cancel_tool
        , Tool_loading_declarations.loading_of_tool Catalog.cancel_tool_name
        , Tool_output.default_model_projection )
      ]
  else composition_tools
;;

let make_tools ~capability_surface =
  make_tools_with_authority
    ~capability_authority:
      (Keeper_tool_runtime.Frozen_surface capability_surface)
    ~descriptors:(Keeper_capability_surface.descriptors capability_surface)
;;

module Compatibility = struct
  let make_tools ~descriptors =
    make_tools_with_authority
      ~capability_authority:Keeper_tool_runtime.Compatibility_meta
      ~descriptors
  ;;
end
