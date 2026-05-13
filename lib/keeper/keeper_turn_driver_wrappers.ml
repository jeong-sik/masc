(** Keeper_turn_driver_wrappers — convenience wrappers extracted from
    [Keeper_turn_driver].

    These are sibling entry points to {!Keeper_turn_driver.run_named}:
    - [run_model_by_label]: explicit model-label variant
    - [run_named_with_masc_tools]: cascade variant + MASC tool bridging
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
    ?(temperature = Cascade_legacy_runner.default_temperature)
    ?(max_tokens = Cascade_legacy_runner.default_max_tokens)
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
    ?contract
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result =
  let stream_idle_timeout_s = apply_stream_idle_timeout_default stream_idle_timeout_s in
  let* config =
    Cascade_error_classify.config_for_label ~name:"oas-label-model" ~model_label ~system_prompt
      ~tools ~max_turns ~max_tokens ?max_input_tokens ?max_cost_usd ~temperature
      ~max_idle_turns ?stream_idle_timeout_s ?guardrails ?hooks ?context_reducer ?memory
      ?tool_retry_policy
      ?enable_thinking
      ?compact_ratio
      ~description:(Some (Printf.sprintf "model_label:%s" model_label))
      ()
  in
  match Cascade_oas_runner.require_eio ?sw ?net () with
  | Error e -> Error (Cascade_oas_runner.eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config = { config with transport = transport_resolved } in
      match
        let admission_cascade_name =
          Keeper_cascade_profile.runtime_name_of_string model_label
        in
        Admission_queue.with_permit ?wait_timeout_sec
          ~priority:Llm_provider.Request_priority.Proactive
          ~keeper_name:"oas-label-model"
          ~cascade_name:admission_cascade_name
          (fun () ->
            Cascade_error_classify.with_codex_cli_preflight
              ~scope:(Printf.sprintf "model_label:%s" model_label)
              ~config ~goal
              (fun () ->
                match Cascade_runner.run ~sw ~net ~config ?on_event ?contract goal with
                | Ok result when accept result.response -> Ok result
                | Ok result ->
                    Error
                      (sdk_error_of_masc_internal_error
                         (Accept_rejected
                            {
                              scope = model_label;
                              model = Some "runtime";
                              reason =
                                Printf.sprintf
                                  "response rejected by accept (runtime=%s)"
                                  "runtime";
                            }))
                | Error e -> Error e))
      with
      | Ok result -> result
      | Error (`Host_resource_saturated reason) ->
          Error
            (sdk_error_of_masc_internal_error
               (Admission_queue_rejected { keeper_name = "oas-label-model"; reason }))

let run_named_with_masc_tools
    ~cascade_name
    ~goal
    ?priority
    ?(system_prompt = "")
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.t)
    ?(max_turns = 20)
    ?stream_idle_timeout_s
    ?(temperature = Cascade_legacy_runner.default_temperature)
    ?(max_tokens = Cascade_legacy_runner.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
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
    ?proof_ref
    ?contract
    ?transport
    ?(yield_on_tool = false)
    ?compact_ratio
    ?approval
    ?sw
    ?net
    ()
  : (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result =
  let oas_tools = List.map (fun (td : Masc_domain.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  Keeper_turn_driver.run_named ~cascade_name ~goal ?priority ~system_prompt ~tools:oas_tools
    ~require_tool_support:(masc_tools <> [])
    ~max_turns ~temperature ~max_tokens ?max_input_tokens ?max_cost_usd
    ?stream_idle_timeout_s ?wait_timeout_sec ?guardrails ?hooks ?memory
    ?tool_retry_policy
    ~required_tool_satisfaction
    ?compact_ratio
    ?approval
    ?raw_trace ?on_event ?on_yield ?on_resume ?proof_ref
    ?contract
    ?transport ~yield_on_tool ?sw ?net ()

let run_model_with_masc_tools
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.t)
    ?(max_turns = 20)
    ?stream_idle_timeout_s
    ?(temperature = Cascade_legacy_runner.default_temperature)
    ?(max_tokens = Cascade_legacy_runner.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?contract
    ?raw_trace
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result =
  let stream_idle_timeout_s = apply_stream_idle_timeout_default stream_idle_timeout_s in
  let* config =
    Cascade_error_classify.config_for_label ~name:"oas-explicit-model" ~model_label ~system_prompt
      ~tools:[] ~max_turns ~max_tokens ?max_input_tokens ?max_cost_usd ~temperature
      ?stream_idle_timeout_s ?guardrails ?hooks ?memory ?tool_retry_policy ?enable_thinking
      ?compact_ratio
      ~description:(Some (Printf.sprintf "model_label:%s" model_label))
      ()
  in
  match Cascade_oas_runner.require_eio ?sw ?net () with
  | Error e -> Error (Cascade_oas_runner.eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config = { config with raw_trace; transport = transport_resolved } in
      match
        let admission_cascade_name =
          Keeper_cascade_profile.runtime_name_of_string model_label
        in
        Admission_queue.with_permit ?wait_timeout_sec
          ~priority:Llm_provider.Request_priority.Proactive
          ~keeper_name:"oas-explicit-model"
          ~cascade_name:admission_cascade_name
          (fun () ->
            Cascade_error_classify.with_codex_cli_preflight
              ~scope:(Printf.sprintf "explicit_model:%s" model_label)
              ~config ~goal
              (fun () ->
                Cascade_runner.run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?contract ?on_event
                  goal))
      with
      | Ok result -> result
      | Error (`Host_resource_saturated reason) ->
          Error
            (sdk_error_of_masc_internal_error
               (Admission_queue_rejected { keeper_name = "oas-explicit-model"; reason }))
