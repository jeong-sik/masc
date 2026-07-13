(* keeper_run_tools_setup — extracted from keeper_run_tools.ml.
   Contains the full implementation of prepare_agent_setup. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

let prepare_agent_setup
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell)
      ~(ctx_work : working_context)
      ~(session : Keeper_types.session_context)
      ~(base_system_prompt : string)
      ~(turn_system_prompt : string)
      ~(user_message : string)
      ~(dynamic_context : string)
      ~(history_messages : Agent_sdk.Types.message list)
      ~(prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics)
      ~(estimated_input_tokens : int)
      ~(max_context : int)
      ~(shared_context : Agent_sdk.Context.t)
      ~(context_injector : Agent_sdk.Hooks.context_injector)
      ~(start_turn_count : int)
      ~(generation : int)
      ~(runtime_id : string)
      ~(is_retry : bool)
      ~(config_root : string)
      ~(runtime_config_path : string option)
      ~(trajectory_acc : Trajectory.accumulator option)
      ?runtime_manifest_context
      ?runtime_manifest_append
      ?continuation_channel
      ?hitl_resolution
      ()
  : (Keeper_run_tools_hooks.agent_setup, Agent_sdk.Error.sdk_error) result
  =
  let runtime_id_string = runtime_id in
  let manifest_keeper_turn_id =
    match runtime_manifest_context with
    | Some ctx -> ctx.Keeper_runtime_manifest.manifest_keeper_turn_id
    | None -> None
  in
  let ctx_snapshot = ctx_work in
  let gate_context =
    Keeper_gate_causal_context.create
      ~turn_id:manifest_keeper_turn_id
      ~initial:
        (`Assoc
           [ ( "history_messages"
             , `List
                 (List.map
                    Keeper_context_core.message_to_json
                    history_messages) )
           ; "base_system_prompt", `String base_system_prompt
           ; "turn_system_prompt", `String turn_system_prompt
           ; "user_message", `String user_message
           ; "dynamic_context", `String dynamic_context
           ; "runtime_id", `String runtime_id
           ])
  in
  let agent_name = meta.agent_name in
  let acc : Keeper_run_tools_hook_accumulator.hook_accumulator =
    { meta
    ; tool_calls = []
    ; current_turn = 0
    ; tool_surface =
        { turn_lane = Keeper_agent_tool_surface.Lane_text_only
        ; config_root
        ; runtime_config_path
        }
    ; requested_tool_names = []
    ; receipt_completion_contract_result =
        Keeper_execution_receipt.Completion_observation_unknown
    ; receipt_actionable_signal = None
    ; prompt_blocks = []
    ; extra_system_context_digest = None
    ; extra_system_context_size = None
    }
  in
  let local_search_fn_ref : (unit -> Yojson.Safe.t) ref =
    ref (fun () -> `Assoc [ "results", `List [] ])
  in
  let { Keeper_tools_oas.tools = keeper_tools; cleanup = keeper_tools_cleanup } =
    Keeper_tools_oas_bundle.make_tool_bundle
      ~config
      ~meta
      ~ctx_snapshot
      ~search_fn:(fun () -> !local_search_fn_ref ())
      ?continuation_channel
      ~gate_context
      ?hitl_resolution
      ()
  in
  let tools = keeper_tools in
  let registered_descriptors = Keeper_tool_descriptor.all_descriptors () in
  let model_visible_descriptors =
    Keeper_tool_descriptor.model_visible_descriptors ()
  in
  let transport_alias_count =
    List.fold_left
      (fun count (descriptor : Keeper_tool_descriptor.t) ->
         match
           Keeper_tool_descriptor.model_schema_errors descriptor
         , descriptor.keeper_model_projection
         with
         | [], Keeper_tool_descriptor.Transport_alias _ -> count + 1
         | _ :: _, _
         | [],
           ( Keeper_tool_descriptor.Preferred_public_name
           | Keeper_tool_descriptor.Internal_name ) -> count)
      0
      registered_descriptors
  in
  let invalid_schema_count =
    List.fold_left
      (fun count (descriptor : Keeper_tool_descriptor.t) ->
         match Keeper_tool_descriptor.model_schema_errors descriptor with
         | [] -> count
         | _ :: _ -> count + 1)
      0
      registered_descriptors
  in
  let unexplained_exclusion_count =
    List.length registered_descriptors
    - List.length model_visible_descriptors
    - transport_alias_count
    - invalid_schema_count
  in
  let tool_context_estimate =
    Keeper_run_prompt.estimate_tool_schema_context ~estimated_input_tokens ~tools
  in
  let all_tool_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) keeper_tools
  in
  let expected_model_names =
    model_visible_descriptors
    |> List.concat_map Keeper_tool_descriptor.keeper_model_names
    |> List.sort_uniq String.compare
  in
  let actual_model_names = List.sort_uniq String.compare all_tool_names in
  let all_model_eligible_tools_visible =
    expected_model_names = actual_model_names
    && List.length actual_model_names = List.length all_tool_names
  in
  if not all_model_eligible_tools_visible
  then
    Log.Keeper.emit
      Log.Error
      ~keeper_name:meta.name
      ~category:Log.Tool
      ~details:
        (`Assoc
           [ "error_kind", `String "keeper_model_tool_projection_mismatch"
           ; "expected_names", Json_util.json_string_list expected_model_names
           ; "actual_names", Json_util.json_string_list all_tool_names
           ])
      "Keeper model tool bundle differs from the descriptor projection";
  let tool_catalog_results =
    keeper_tools
    |> List.map (fun (tool : Agent_sdk.Tool.t) ->
      `Assoc
        [ "name", `String tool.schema.name
        ; "description", `String tool.schema.description
        ; ( "input_schema"
          , Agent_sdk.Types.params_to_input_schema tool.schema.parameters )
        ; "already_visible", `Bool true
        ])
  in
  (local_search_fn_ref
   := fun () ->
        `Assoc
          [ "ok", `Bool true
          ; "results", `List tool_catalog_results
          ; "result_count", `Int (List.length tool_catalog_results)
          ; "registered_descriptor_count", `Int (List.length registered_descriptors)
          ; "model_visible_descriptor_count", `Int (List.length model_visible_descriptors)
          ; "transport_alias_count", `Int transport_alias_count
          ; "invalid_schema_count", `Int invalid_schema_count
          ; "unexplained_exclusion_count", `Int unexplained_exclusion_count
          ; ( "all_model_eligible_tools_visible"
            , `Bool all_model_eligible_tools_visible )
          ]);
  Log.Keeper.routine
    "keeper:%s tool visibility: registered=%d visible=%d transport_alias=%d \
     invalid_schema=%d unexplained=%d"
    meta.name
    (List.length registered_descriptors)
    (List.length all_tool_names)
    transport_alias_count
    invalid_schema_count
    unexplained_exclusion_count;
  let record_tool_assignment ~turn ~tool_list ~lane =
    let (_assignment_id : Tool_assignment_telemetry.assignment_id) =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:meta.agent_name
        ~profile:"keeper"
        ~tool_list
        ~reason:
          (Printf.sprintf
             "keeper before_turn tool surface turn=%d lane=%s"
             turn
             (Keeper_agent_tool_surface.turn_lane_to_string lane))
        ()
    in
    ()
  in
  let receipt_turn_count_ref : int option ref = ref None in
  let receipt_model_used_ref : string option ref = ref None in
  let receipt_stop_reason_ref : Runtime_agent.stop_reason option ref =
    ref None
  in
  let receipt_runtime_observation_ref
    : Runtime_observation.runtime_observation option ref
    =
    ref None
  in
  let receipt_response_text_present_ref = ref false in
  let compute_tool_surface
        ~turn:_
        ~current_tool_choice
        ()
    : string list * turn_lane
    =
    let schema_filter = all_tool_names in
    let lane : Keeper_agent_tool_surface.turn_lane =
      if is_retry
      then Lane_retry
      else if schema_filter <> []
      then Lane_tool_optional
      else (
        match current_tool_choice with
        | Some Agent_sdk.Types.None_ -> Lane_tool_disabled
        | _ -> Lane_text_only)
    in
    (schema_filter, lane)
  in

  let ctx : Keeper_run_tools_hooks.ctx =
    { acc
    ; agent_name
    ; all_tool_names
    ; compute_tool_surface
    ; record_tool_assignment
    ; config
    ; keeper_tools_cleanup
    ; manifest_keeper_turn_id
    ; max_context
    ; meta
    ; tool_context_estimate
    ; turn_ctx_cell
    ; receipt_turn_count_ref
    ; receipt_model_used_ref
    ; receipt_stop_reason_ref
    ; receipt_runtime_observation_ref
    ; receipt_response_text_present_ref
    ; tools
    }
  in
  Keeper_run_tools_hooks.assemble_hooks
    ~ctx ~session ~turn_system_prompt ~user_message ~dynamic_context
    ~history_messages ~prompt_metrics ~shared_context
    ~start_turn_count ~generation
    ~runtime_id_string ~is_retry
    ~config_root ~runtime_config_path
    ~trajectory_acc
    ?runtime_manifest_context ?runtime_manifest_append ()
