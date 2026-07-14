type invoke =
  sw:Eio.Switch.t
  -> runtime_id:string
  -> base_path:string
  -> keeper_name:string
  -> system_prompt:string
  -> user_prompt:string
  -> provider_config_transform:
       (Llm_provider.Provider_config.t
        -> (Llm_provider.Provider_config.t, Agent_sdk.Error.sdk_error) result)
  -> (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result

let apply_output_contract output_schema provider_cfg =
  Ok
    (Keeper_structured_output_schema.apply_schema_or_prompt_tier
       ~log_label:"typed tool-failure recovery judge"
       output_schema
       provider_cfg)
;;

let completion ~resolve_runtime ~(invoke : invoke) ~base_path ~keeper_name ~sw request =
  let runtime_id = resolve_runtime () in
  let provider_config_transform =
    apply_output_contract request.Agent_sdk.Tool_failure_recovery.output_schema
  in
  invoke
    ~sw
    ~runtime_id
    ~base_path
    ~keeper_name
    ~system_prompt:request.system_prompt
    ~user_prompt:request.user_prompt
    ~provider_config_transform
  |> Result.map Agent_sdk.Types.text_of_response
;;

let invoke
      ~sw
      ~runtime_id
      ~base_path
      ~keeper_name
      ~system_prompt
      ~user_prompt
      ~provider_config_transform
  =
  Keeper_turn_driver.run_named
    ~runtime_id
    ~keeper_name
    ~base_path
    ~goal:user_prompt
    ~system_prompt
    ~max_idle_turns:0
    ~accept:(fun response ->
      not (String.equal (String.trim (Agent_sdk.Types.text_of_response response)) ""))
    ~provider_config_transform
    ~sw
    ()
  |> Result.map (fun result -> result.Runtime_agent.response)
;;

let create ~base_path ~keeper_name =
  Agent_sdk.Tool_failure_recovery.create
    ~complete:
      (completion
         ~resolve_runtime:Runtime.runtime_id_for_structured_judge
         ~invoke
         ~base_path
         ~keeper_name)
;;

module For_testing = struct
  type nonrec invoke = invoke

  let completion = completion
end
