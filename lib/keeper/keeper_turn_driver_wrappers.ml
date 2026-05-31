(** Keeper_turn_driver_wrappers — convenience wrappers extracted from
    [Keeper_turn_driver].

    These are sibling entry points to {!Keeper_turn_driver.run_named}:
    - [run_model_by_label]: explicit model-label variant
    - [run_named_with_masc_tools]: runtime variant + MASC tool bridging
    - [run_model_with_masc_tools]: model-label variant + MASC tool bridging

    Extracted from keeper_turn_driver.ml as RFC-0048 PR-2 to reduce the
    1347-LOC hotspot file.

    @since RFC-0048 PR-2 *)

open Result.Syntax
include Keeper_turn_driver

let run_model_by_label
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?stream_idle_timeout_s
    ?(temperature = Llm_provider.Constants.Inference_profile.agent_default.temperature)
    ?(max_tokens = Llm_provider.Constants.Inference_profile.agent_default.max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?(accept = fun (_ : Agent_sdk_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  Keeper_turn_driver.run_named
    ~runtime_id:model_label
    ~goal
    ~system_prompt
    ~tools
    ~max_turns
    ~max_idle_turns
    ?stream_idle_timeout_s
    ~temperature
    ~max_tokens
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ~accept
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?on_event
    ?transport
    ?sw
    ?net
    ()

let run_named_with_masc_tools
    ~runtime_id
    ~goal
    ?priority
    ?(system_prompt = "")
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ?(max_turns = 20)
    ?stream_idle_timeout_s
    ?(temperature = Llm_provider.Constants.Inference_profile.agent_default.temperature)
    ?(max_tokens = Llm_provider.Constants.Inference_profile.agent_default.max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?(accept = fun (_ : Agent_sdk_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
    ?(required_tool_satisfaction =
      Agent_sdk.Completion_contract.any_tool_call_satisfies)
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?transport
    ?(yield_on_tool = false)
    ?compact_ratio
    ?approval
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  let oas_tools = List.map (fun (td : Masc_domain.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  Keeper_turn_driver.run_named ~runtime_id ~goal ?priority ~system_prompt ~tools:oas_tools
    ~require_tool_support:(masc_tools <> [])
    ~max_turns ~temperature ~max_tokens ?max_input_tokens ?max_cost_usd
    ?stream_idle_timeout_s ?wait_timeout_sec ?guardrails ?hooks ?memory
    ?tool_retry_policy
    ~required_tool_satisfaction
    ~accept
    ?compact_ratio
    ?approval
    ?raw_trace ?on_event ?on_yield ?on_resume 
    ?transport ~yield_on_tool ?sw ?net ()

let run_model_with_masc_tools
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ?(max_turns = 20)
    ?stream_idle_timeout_s
    ?(temperature = Llm_provider.Constants.Inference_profile.agent_default.temperature)
    ?(max_tokens = Llm_provider.Constants.Inference_profile.agent_default.max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?raw_trace
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  let oas_tools =
    List.map
      (fun (td : Masc_domain.tool_schema) ->
         Tool_bridge.oas_tool_of_masc
           ~name:td.name
           ~description:td.description
           ~input_schema:td.input_schema
           (fun input -> dispatch ~name:td.name ~args:input))
      masc_tools
  in
  Keeper_turn_driver.run_named
    ~runtime_id:model_label
    ~goal
    ~system_prompt
    ~tools:oas_tools
    ~require_tool_support:(masc_tools <> [])
    ~max_turns
    ?stream_idle_timeout_s
    ~temperature
    ~max_tokens
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?raw_trace
    ?on_event
    ?transport
    ?sw
    ?net
    ()
