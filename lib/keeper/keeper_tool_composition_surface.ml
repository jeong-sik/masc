module Catalog = Keeper_tool_composition_catalog
module Executor = Keeper_tool_plan_executor
module Activation_ledger = Keeper_skill_activation_ledger

let composition_run_summary_tool_name = "keeper_composition_run_summary"

(* Composition tools are materialized Agent_core tools outside the Keeper
   descriptor registry, so their tool kind is observable through their own
   result payloads and node telemetry — never through descriptor route
   evidence. *)
let tool_kind_field kind =
  "tool_kind", `String (Keeper_tool_descriptor.tool_kind_to_string kind)
;;

let with_tool_kind_field kind = function
  | `Assoc fields -> `Assoc (tool_kind_field kind :: fields)
  | json -> json
;;

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

let instruction_skill_description (instruction_skills : instruction_skill list) =
  let listed =
    instruction_skills
    |> List.map (fun (skill : instruction_skill) ->
         Printf.sprintf
           "%s: %s"
           (Skill_reference.to_yojson skill.reference |> Yojson.Safe.to_string)
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

let schema_tool_of_entry (entry : Catalog.entry) =
  schema_tool
    ~name:(Catalog.tool_name entry)
    ~description:(entry_description entry)
    ~input_schema:(Catalog.input_schema_of_params entry.params)
;;

let schema_tool_rows ?(skill_compositions = []) () =
  let composition_tools =
    List.map
      (fun (entry, evidence) ->
         Declared_composition evidence, schema_tool_of_entry entry)
      skill_compositions
  in
  composition_tools
  @ [ ( Async_status
      , schema_tool
          ~name:Catalog.status_tool_name
          ~description:Tool_schemas_composition_control.status_schema.description
          ~input_schema:Tool_schemas_composition_control.status_schema.input_schema )
    ; ( Async_cancel
      , schema_tool
          ~name:Catalog.cancel_tool_name
          ~description:Tool_schemas_composition_control.cancel_schema.description
          ~input_schema:Tool_schemas_composition_control.cancel_schema.input_schema )
    ]
;;

let schedule_to_json (schedule : Agent_core.Tool_contract.schedule) =
  `Assoc
    [ "planned_index", `Int schedule.planned_index
    ; "batch_index", `Int schedule.batch_index
    ; "batch_size", `Int schedule.batch_size
    ; ( "execution_mode"
      , Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode )
    ]
;;

let failure_effect_disposition_to_json = function
  | None -> `Null
  | Some disposition ->
    `String (Tool_result.failure_effect_disposition_to_string disposition)
;;

let deferred_kind_to_json = function
  | None -> `Null
  | Some kind -> `String (Keeper_tool_execution.deferred_kind_to_string kind)
;;

let node_result_to_json (result : Executor.node_result) =
  `Assoc
    [ "node_id", `String (Keeper_tool_plan.Node_id.to_string result.node_id)
    ; "execution_id", Ids.Execution_id.to_yojson result.execution_id
    ; "tool_name", `String result.tool_name
    ; "input", result.input
    ; "schedule", schedule_to_json result.schedule
    ; "result", Tool_result.to_json result.result
    ; "tool_use_id", `String result.tool_use_id
    ; ( "failure_effect_disposition"
      , failure_effect_disposition_to_json result.failure_effect_disposition )
    ; "deferred_kind", deferred_kind_to_json result.deferred_kind
    ; "result_bytes", `Int result.result_bytes
    ; "truncated_to", Json_util.int_opt_to_json result.truncated_to
    ]
;;

let observe_node_result
      ~composition_tool
      ~composition_execution
      ~composition_tool_kind
      ~composition_run_id
      ~parent_invocation
      ~meta
      ~(turn_context : Keeper_tool_call_log_context.turn_context)
      (result : Executor.node_result)
  =
  let observe () =
    let context = turn_context in
    let schedule = result.schedule in
    let committed = ref false in
    Keeper_tool_call_log.log_call
      ~keeper_name:meta.Keeper_meta_contract.name
      ~tool_name:result.tool_name
      ~input:result.input
      ~output_text:(Tool_result.message result.result)
      ~success:(Tool_result.is_success result.result)
      ~duration_ms:(Tool_result.duration_ms result.result)
      ~model:(Keeper_hooks_agent_core_types.current_keeper_model meta)
      ?agent_name:context.agent_name
      ?turn_kind:context.turn_kind
      ?lane:context.lane
      ?tool_choice:context.tool_choice
      ?thinking_enabled:context.thinking_enabled
      ?thinking_budget:context.thinking_budget
      ?prompt_fingerprint:context.prompt_fingerprint
      ~execution_id:result.execution_id
      ~tool_use_id:result.tool_use_id
      ~planned_index:schedule.planned_index
      ~batch_index:schedule.batch_index
      ~batch_size:schedule.batch_size
      ~execution_mode:schedule.execution_mode
      ~typed_result:result.result
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
      ~turn:(Agent_core.Tool_contract.Invocation.turn parent_invocation)
      ?keeper_turn_id:context.keeper_turn_id
      ?task_id:context.task_id
      ?sandbox_profile:context.sandbox_profile
      ?sandbox_root:context.sandbox_root
      ?sandbox_roots:context.sandbox_roots
      ?network_mode:context.network_mode
      ?runtime_profile:context.runtime_profile
      ~on_committed:(fun () -> committed := true)
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
      ; "success", `Bool (Tool_result.is_success result.result)
      ; "duration_ms", `Float (Tool_result.duration_ms result.result)
      ; "disposition", `String (Tool_result.string_of_disposition result.result)
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
    Log.Keeper.warn
      "composition action telemetry degraded without changing execution: tool=%s node=%s error=%s"
      composition_tool
      (Keeper_tool_plan.Node_id.to_string result.node_id)
      (Printexc.to_string exn);
    Ok ()
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
      ~success
      ~duration_ms
      ~record_kind:Keeper_tool_call_log.Composition_run
      ~model:(Keeper_hooks_agent_core_types.current_keeper_model meta)
      ?agent_name:(field (fun context -> context.Keeper_tool_call_log_context.agent_name))
      ?turn_kind:(field (fun context -> context.turn_kind))
      ?lane:(field (fun context -> context.lane))
      ?tool_choice:(field (fun context -> context.tool_choice))
      ?thinking_enabled:(field (fun context -> context.thinking_enabled))
      ?thinking_budget:(field (fun context -> context.thinking_budget))
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
      match entry.Keeper_msg_async.status with
      | Keeper_msg_async.Done { ok; body; data = _ } -> Some (ok, body)
      | Keeper_msg_async.Lost { reason } -> Some (false, reason)
      | Keeper_msg_async.Cancelled { reason; cancelled_by } ->
        Some (false, Printf.sprintf "%s: %s" cancelled_by reason)
      | Keeper_msg_async.Persistence_failed { attempted_status; reason } ->
        Some (false, Printf.sprintf "persisting %s failed: %s" attempted_status reason)
      | Keeper_msg_async.Queued
      | Keeper_msg_async.Running
      | Keeper_msg_async.Cancelling _ -> None
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

let json_type_to_string = function
  | Keeper_tool_plan.Null_type -> "null"
  | Keeper_tool_plan.Boolean_type -> "boolean"
  | Keeper_tool_plan.Integer_type -> "integer"
  | Keeper_tool_plan.Number_type -> "number"
  | Keeper_tool_plan.String_type -> "string"
  | Keeper_tool_plan.Array_type -> "array"
  | Keeper_tool_plan.Object_type -> "object"
;;

let path_to_json path = `List (List.map (fun segment -> `String segment) path)

let schema_value_error_to_json = function
  | Keeper_tool_plan.Unsupported_schema_type schema ->
    `Assoc
      [ "kind", `String "unsupported_schema_type"
      ; "schema", schema
      ]
  | Keeper_tool_plan.Missing_required_field { path; field } ->
    `Assoc
      [ "kind", `String "missing_required_field"
      ; "path", path_to_json path
      ; "field", `String field
      ]
  | Keeper_tool_plan.Unexpected_field { path; field } ->
    `Assoc
      [ "kind", `String "unexpected_field"
      ; "path", path_to_json path
      ; "field", `String field
      ]
  | Keeper_tool_plan.Duplicate_value_field { path; field } ->
    `Assoc
      [ "kind", `String "duplicate_value_field"
      ; "path", path_to_json path
      ; "field", `String field
      ]
  | Keeper_tool_plan.Type_mismatch { path; expected; actual } ->
    `Assoc
      [ "kind", `String "type_mismatch"
      ; "path", path_to_json path
      ; "expected", `String (json_type_to_string expected)
      ; "actual", `String (json_type_to_string actual)
      ]
;;

let pointer_resolution_error_to_json = function
  | Keeper_tool_plan.Json_pointer.Missing_object_field field ->
    `Assoc
      [ "kind", `String "missing_object_field"
      ; "field", `String field
      ]
  | Keeper_tool_plan.Json_pointer.Ambiguous_object_field field ->
    `Assoc
      [ "kind", `String "ambiguous_object_field"
      ; "field", `String field
      ]
  | Keeper_tool_plan.Json_pointer.Invalid_array_index index ->
    `Assoc
      [ "kind", `String "invalid_array_index"
      ; "index", `String index
      ]
  | Keeper_tool_plan.Json_pointer.Array_index_out_of_bounds index ->
    `Assoc
      [ "kind", `String "array_index_out_of_bounds"
      ; "index", `Int index
      ]
  | Keeper_tool_plan.Json_pointer.Expected_container segment ->
    `Assoc
      [ "kind", `String "expected_container"
      ; "segment", `String segment
      ]
;;

let template_resolution_error_to_json = function
  | Keeper_tool_plan.Json_template.Missing_output node_id ->
    `Assoc
      [ "kind", `String "missing_output"
      ; "source_node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ]
  | Keeper_tool_plan.Json_template.Pointer_resolution_failed { node_id; error } ->
    `Assoc
      [ "kind", `String "pointer_resolution_failed"
      ; "source_node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "error", pointer_resolution_error_to_json error
      ]
  | Keeper_tool_plan.Json_template.Param_not_substituted name ->
    `Assoc
      [ "kind", `String "param_not_substituted"; "param", `String name ]
;;

let plan_execution_error_to_json = function
  | Keeper_tool_plan.Unknown_node_id node_id ->
    `Assoc
      [ "kind", `String "unknown_node_id"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ]
  | Keeper_tool_plan.Input_template_resolution_failed { node_id; error } ->
    `Assoc
      [ "kind", `String "input_template_resolution_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "error", template_resolution_error_to_json error
      ]
  | Keeper_tool_plan.Input_validation_failed { node_id; tool_name; rejection } ->
    `Assoc
      [ "kind", `String "input_validation_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "tool_name", `String tool_name
      ; "rejection", Tool_result.to_json rejection
      ]
  | Keeper_tool_plan.Output_validation_failed { node_id; tool_name; error } ->
    `Assoc
      [ "kind", `String "output_validation_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "tool_name", `String tool_name
      ; "error", schema_value_error_to_json error
      ]
  | Keeper_tool_plan.Output_not_composable { node_id; tool_name } ->
    `Assoc
      [ "kind", `String "output_not_composable"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "tool_name", `String tool_name
      ]
;;

let cause_to_json = function
  | Executor.Tool_did_not_complete result ->
    `Assoc
      [ "kind", `String "tool_did_not_complete"
      ; "node", node_result_to_json result
      ]
  | Executor.Node_observation_failed { node; detail } ->
    `Assoc
      [ "kind", `String "node_observation_failed"
      ; "node", node_result_to_json node
      ; "detail", `String detail
      ]
  | Executor.Plan_execution_failed { node_id; schedule; error } ->
    `Assoc
      [ "kind", `String "plan_execution_failed"
      ; "node_id", `String (Keeper_tool_plan.Node_id.to_string node_id)
      ; "schedule", schedule_to_json schedule
      ; "error", plan_execution_error_to_json error
      ]
  | Executor.Outer_completion_mismatch { expected; actual } ->
    `Assoc
      [ "kind", `String "outer_completion_mismatch"
      ; "expected", Agent_core.Tool_contract.completion_to_yojson expected
      ; "actual", Agent_core.Tool_contract.completion_to_yojson actual
      ]
;;

(* Why the failure comes before the settled nodes.

   This payload is what the durable tool-call row carries, and that row is
   truncated to [Keeper_tool_call_log.max_output_len] bytes on the serialized
   string. [settled] grows with the plan -- a node returning a task list put
   12KB in one row -- so with [settled] first the cut landed inside it and
   [cause] never reached disk. Eight failures of one composition on
   2026-09-03 were recorded with no readable reason for that exact ordering.

   [cause] and [effect_disposition] are bounded; [settled] is not. The
   unbounded field goes last so the diagnosis survives the cut. *)
let failure_payload ~tool_name ~tool_kind ~cause ~effect_disposition ~settled =
  `Assoc
    (("composition_tool", `String tool_name)
     :: tool_kind_field tool_kind
     :: [ "cause", cause
        ; "effect_disposition", `String effect_disposition
        ; "settled", `List settled
        ])
;;

let failure_data ~tool_name ~tool_kind (failure : Executor.failure) =
  failure_payload
    ~tool_name
    ~tool_kind
    ~cause:(cause_to_json failure.cause)
    ~effect_disposition:
      (Tool_result.failure_effect_disposition_to_string failure.effect_disposition)
    ~settled:(List.map node_result_to_json failure.settled)
;;

let failure_class (failure : Executor.failure) =
  match failure.cause with
  | Executor.Tool_did_not_complete result ->
    Option.value
      ~default:Tool_result.Runtime_failure
      (Tool_result.failure_class result.result)
  | Executor.Plan_execution_failed _
  | Executor.Node_observation_failed _
  | Executor.Outer_completion_mismatch _ ->
    Tool_result.Runtime_failure
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
  | Error failure ->
    let data = failure_data ~tool_name ~tool_kind failure in
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~start_time
      ~data
      (Yojson.Safe.to_string data)
;;

let evidence_nodes_of_execution = function
  | Ok settled -> List.map node_result_to_json settled
  | Error failure -> List.map node_result_to_json failure.Executor.settled
;;

let record_skill_composition_evidence
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
    Log.Keeper.warn
      "Skill composition evidence publication failed: tool=%s run=%s error=%s"
      composition_tool
      (Keeper_tool_plan.Composition_run_id.to_string composition_run_id)
      detail;
    (try
       Telemetry_coverage_gap.record
         ~masc_root:(Workspace.masc_root_dir config)
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

let execute_keeper_plan ~capability_authority =
  match capability_authority with
  | Keeper_tool_runtime.Frozen_surface capability_surface ->
    Executor.execute_keeper ~capability_surface
  | Keeper_tool_runtime.Compatibility_meta ->
    Executor.Compatibility.execute_keeper
;;

let async_worker_result
      ~composition_execution
      ~tool_kind
      ?skill_reference
      ~plan
      ~tool_name
      ~request_id
      ~composition_run_id
      ~source_invocation
      ~request_sw
      ~(config : Workspace.config)
      ~meta
      ~capability_authority
      ~publication_recovery
      ~ctx_snapshot
      ~turn_context
      ?clock
      ()
  =
  Eio_context.with_turn_switch request_sw
  @@ fun () ->
  let sandbox_factory = Keeper_sandbox_factory.create ~config ~meta () in
  Eio.Switch.on_release request_sw (fun () ->
    Keeper_sandbox_factory.cleanup sandbox_factory);
  let start_time = Time_compat.now () in
  let run_id = Keeper_tool_plan.Run_id.fresh () in
  let execution =
    execute_keeper_plan
    ~capability_authority
    ~plan
    ~run_id
    ~composition_run_id
    ~parent_invocation:
      (async_parent_invocation ~request_id source_invocation)
    ~config
    ~meta
    ~publication_recovery
    ~ctx_snapshot
    ~turn_sandbox_factory:sandbox_factory
    ?observe_node_result:
      (Option.map
         (fun turn_context ->
            observe_node_result
              ~composition_tool:tool_name
              ~composition_execution
              ~composition_tool_kind:tool_kind
              ~composition_run_id
              ~parent_invocation:source_invocation
              ~meta
              ~turn_context)
         turn_context)
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
  Option.iter
    (fun reference ->
       record_skill_composition_evidence
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
  result
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

let async_submission_result
      ?skill_reference
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
  let start_time = Time_compat.now () in
  let composition_run_id = Keeper_tool_plan.Composition_run_id.fresh () in
  let request_context_fields =
    [ ( "composition_run_id"
      , `String
          (Keeper_tool_plan.Composition_run_id.to_string composition_run_id) ) ]
    @ Option.to_list
        (Option.map
           (fun reference -> "skill_reference", Skill_reference.to_yojson reference)
           skill_reference)
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
    (match
       Keeper_msg_async.submit_with_request_id
         ?request_context
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
             settlement)
         ~f:(fun ~request_id request_sw ->
           async_worker_result
             ~composition_execution:Catalog.Async
             ~tool_kind
             ?skill_reference
             ~plan
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
         ()
     with
     | Error error ->
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
           (* Says the wake exists. Without it the only way to learn the
              result is to poll keeper_composition_status, which is the habit
              that left results sitting a median of 21.9s. *)
           ; ( "delivery"
             , `String
                 "async: you will be woken with the result when this \
                  composition settles. Read it with keeper_composition_status \
                  and this request_id; there is no need to poll for it." )
              ; "submission", Keeper_msg_async.submit_outcome_to_json outcome
              ])
       in
       result_from_json
         ~tool_name
         ~start_time
         ~class_:Tool_result.Runtime_failure
         ~ok:true
         data
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
;;

let status_result
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~request_id
  =
  let tool_name = Catalog.status_tool_name in
  let start_time = Time_compat.now () in
  let with_kind = with_tool_kind_field Catalog.status_tool_kind in
  match
    Keeper_msg_async.poll
      ~base_path:config.base_path
      ~caller:meta.name
      request_id
  with
  | Keeper_msg_async.Found entry ->
    let result =
      result_from_json
        ~tool_name
        ~start_time
        ~class_:Tool_result.Runtime_failure
        ~ok:true
        (with_kind (Keeper_msg_async.entry_to_json entry))
    in
    (match Tool_bridge.attach_artifact_manifest ~base_path:config.base_path result with
     | Ok result -> result
     | Error { message; _ } ->
       Tool_result.make_err
         ~tool_name
         ~class_:Tool_result.Runtime_failure
         ~start_time
         ("async composition status manifest persistence failed: " ^ message))
  | Keeper_msg_async.Absent ->
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

let cancel_result
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~request_id
  =
  let tool_name = Catalog.cancel_tool_name in
  let start_time = Time_compat.now () in
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
      ~handle
  =
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~descriptor
    ~base_path:config.base_path
    ~name
    ~description
    ~input_schema
    (fun _execution_env input ->
      let start_time = Time_compat.now () in
      match
        Tool_input_validation.validate_args
          ~schema:input_schema
          ~name
          ~args:input
          ()
      with
      | Error rejection -> rejection
      | Ok _ ->
        (match request_id_of_validated_input input with
         | Some request_id -> handle request_id
         | None ->
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
    (match Skill_reference.of_yojson reference_json with
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
      ~instruction_skills
      ()
  =
  let name = Catalog.skill_tool_name in
  let description = instruction_skill_description instruction_skills in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~base_path:config.base_path
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name
    ~description
    ~input_schema:skill_reference_input_schema
    (fun execution_env input ->
      let start_time = Time_compat.now () in
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
           (match
              List.find_opt
                (fun (skill : instruction_skill) ->
                   Skill_reference.equal skill.reference asked)
                instruction_skills
            with
            | Some skill ->
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
                  match record_activation with
                  | Some record ->
                    (match record ~invocation ~content reference with
                     | Error error ->
                       activation_failure
                         ~reference
                         ~tool_name:name
                         ~start_time
                         error
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
                         Digestif.SHA256.(digest_string skill.body |> to_hex) )
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
                         Digestif.SHA256.(digest_string contents |> to_hex)
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
              None ->
              Tool_result.make_err ~tool_name:name
                ~class_:Tool_result.Workflow_rejection ~start_time
                (Printf.sprintf
                   "no instruction Skill matches exact reference %s; this keeper carries: %s"
                   (Skill_reference.to_yojson asked |> Yojson.Safe.to_string)
                   (carried_references_text instruction_skills))))))
;;

module For_testing = struct
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
    let descriptor =
      match entry.execution, completion with
      | Catalog.Async, Agent_core.Tool_contract.Continue_after_success
      | Catalog.Inline, Agent_core.Tool_contract.Continue_after_success ->
        Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Serial
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
    Tool_bridge.agent_core_tool_of_masc_with_execution_env
      ~descriptor
      ~base_path:config.base_path
      ?on_externalization_error:tool_externalization_error
      ~name:tool_name
      ~description:(entry_description entry)
      ~input_schema:(Catalog.input_schema_of_params entry.params)
      (fun execution_env input ->
        let start_time = Time_compat.now () in
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
             let turn_context =
               Option.map
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
                   (match record_composition_activation with
                    | Some record ->
                      (match
                         record
                           ~invocation:parent_invocation
                           ~tool_name
                           ~reference:skill.reference
                       with
                       | Error error ->
                         activation_failure ~tool_name ~start_time error
                       | Ok
                           ( Activation_ledger.Recorded _
                           | Activation_ledger.Already_recorded _ ) ->
                         async_submission_result
                           ~skill_reference:skill.reference
                           ~plan
                           ~tool_name
                           ~tool_kind:(Catalog.tool_kind entry)
                           ~parent_invocation
                           ~config
                           ~meta
                           ~capability_authority
                           ~publication_recovery
                           ~ctx_snapshot
                           ~turn_context
                           ?clock
                           ())
                    | None ->
                      async_submission_result
                        ~skill_reference:skill.reference
                        ~plan
                        ~tool_name
                        ~tool_kind:(Catalog.tool_kind entry)
                        ~parent_invocation
                        ~config
                        ~meta
                        ~capability_authority
                        ~publication_recovery
                        ~ctx_snapshot
                        ~turn_context
                        ?clock
                        ()))
              | Catalog.Inline ->
                (match
                   Catalog.instantiate
                     ~descriptors
                     ~args:input
                     entry
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
             let execution =
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
                 ?turn_sandbox_factory
                 ?clock
                 ?continuation_channel
                 ?gate_context
                 ?gate_grant
                 ?record_gate_result
                 ?on_completed
                 ?on_deferred
                 ?on_external_effect_deferred
                 ?on_failed
                 ?observe_node_result:
                   (Option.map
                      (fun turn_context ->
                         observe_node_result
                           ~composition_tool:tool_name
                           ~composition_execution:entry.execution
                           ~composition_tool_kind:(Catalog.tool_kind entry)
                           ~composition_run_id
                           ~parent_invocation
                           ~meta
                           ~turn_context)
                      turn_context)
                 ()
             in
             (match execution with
              | Error
                  ({ Executor.effect_disposition =
                       ( Tool_result.Proven_post_effect
                       | Tool_result.Effect_outcome_unknown )
                   ; _
                   } as failure) ->
                (* The aggregate is computed from every settled sibling and all
                   earlier batches.  It is the boundary authority: a selected
                   Deferred cause must not hide an earlier committed write or
                   a sibling's unknown/post-effect failure.  Composition
                   execution has no persisted cursor, so only an entirely
                   proven-pre-effect defer may remain resumable. *)
                Option.iter
                  (fun mark_failed ->
                     let diagnostic =
                       failure_data
                         ~tool_name
                         ~tool_kind:(Catalog.tool_kind entry)
                         failure
                       |> Yojson.Safe.to_string
                     in
                     mark_failed
                       { Keeper_tools_agent_core.failure_class =
                           failure_class failure
                       ; effect_disposition = failure.effect_disposition
                       ; diagnostic
                       })
                  on_failed
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
                 Tool_bridge.attach_artifact_manifest
                   ~base_path:config.base_path
                   executor_result
               with
               | Ok result -> result
               | Error { message; _ } ->
                 let diagnostic =
                   "composition result manifest persistence failed: " ^ message
                 in
                 Option.iter
                   (fun mark_failed ->
                      mark_failed
                        { Keeper_tools_agent_core.failure_class =
                            Tool_result.Runtime_failure
                        ; effect_disposition = Tool_result.Effect_outcome_unknown
                        ; diagnostic
                        })
                   on_failed;
                 Tool_result.make_err
                   ~tool_name
                   ~class_:Tool_result.Runtime_failure
                   ~start_time
                   "composition result manifest persistence failed"
             in
             record_skill_composition_evidence
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
             result))))))
  in
  (* A keeper with no instruction skills gets no tool: an empty [Available]
     list would ask the model to reach for something that answers nothing. *)
  let composition_tools =
    match instruction_skills with
    | [] -> composition_tools
    | skills ->
      composition_tools
      @ [ make_instruction_skill_tool
            ~config
            ?record_activation:record_instruction_activation
            ~instruction_skills:skills
            ()
        ]
  in
  let status_tool =
      make_request_control_tool
        ~config
        ~name:Catalog.status_tool_name
        ~description:Tool_schemas_composition_control.status_schema.description
        ~input_schema:Tool_schemas_composition_control.status_schema.input_schema
        ~descriptor:
          (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
        ~handle:(fun request_id -> status_result ~config ~meta ~request_id)
  in
  let cancel_tool =
      make_request_control_tool
        ~config
        ~name:Catalog.cancel_tool_name
        ~description:Tool_schemas_composition_control.cancel_schema.description
        ~input_schema:Tool_schemas_composition_control.cancel_schema.input_schema
        ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Serial)
        ~handle:(fun request_id -> cancel_result ~config ~meta ~request_id)
  in
  composition_tools @ [ status_tool; cancel_tool ]
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
