(** Keeper_turn_driver_wrappers — convenience wrappers around
    {!Keeper_turn_driver.run_named}.

    - [run_named_with_masc_tools]: runtime variant + MASC tool bridging

    @since RFC-0048 PR-2 *)

open Result.Syntax
include Keeper_turn_driver

(* Bridges [masc_tools] into agent-core tools, runs
   [Keeper_turn_driver.run_named], and reports the selected runtime id through
   [on_selected_runtime]. *)
let run_named_with_masc_tools
    ~runtime_id
    ?(keeper_name = "")
    ~walk_owner
    ~input_source
    ~goal
    ?goal_blocks
    ~base_path
    ~media_store
    ~system_prompt
    ?tool_requirement
    ?required_native_posture
    ?tool_result_projection
    ?on_selected_runtime
    ?on_request_execution_ready
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~raw_trace
    ?on_yield
    ?on_resume
    ?attempt_continuation
    ?on_runtime_attempt_error
    ?context
    ?output_contract
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_core.Error.t) result =
  let bridged_tools = List.map (fun (td : Masc_domain.tool_schema) ->
    Tool_bridge.agent_core_tool_of_masc
      ~base_path
      ?model_projection:tool_result_projection
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  let+ selected =
    Keeper_turn_driver.run_named
      ~runtime_id
        ~keeper_name
      ~walk_owner
      ~input_source
      ~goal
      ?goal_blocks
      ~base_path
      ~media_store
      ~system_prompt
      ~tools:bridged_tools
      ~agent_core_tools:bridged_tools
      ?tool_requirement
      ?required_native_posture
      ~raw_trace
      ?on_yield
      ?on_resume
      ?attempt_continuation
      ?on_runtime_attempt_error
      ?on_request_execution_ready
      ?context
      ?output_contract
      ?provider_config_transform
      ?sw
      ?net
      ()
  in
  Option.iter (fun observe -> observe selected.selected_runtime_id) on_selected_runtime;
  selected.run_result
