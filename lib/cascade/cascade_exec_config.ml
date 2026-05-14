(** Cascade_exec_config — OAS execution config helpers.

    This module intentionally carries the heavy provider/runtime dependencies
    that structured error classification must not depend on. *)

open Result.Syntax

let config_for_label
    ~(name : string)
    ~(model_label : string)
    ~(system_prompt : string)
    ~(tools : Agent_sdk.Tool.t list)
    ~(max_turns : int)
    ~(max_tokens : int)
    ?(max_input_tokens : int option)
    ?(max_cost_usd : float option)
    ~(temperature : float)
    ?(max_idle_turns = 3)
    ?stream_idle_timeout_s
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?enable_thinking
    ?compact_ratio
    ?contract
    ?approval
    ~(description : string option)
    () : (Cascade_runner.config, Agent_sdk.Error.sdk_error) result =
  let* provider =
    Cascade_runner.resolve_provider_config_of_label model_label
    |> Result.map_error Cascade_runner.label_resolution_error_to_sdk_error
  in
  Ok
    {
      (Cascade_runner.default_config ~name ~provider_cfg:provider
         ~system_prompt ~tools)
      with
      max_turns;
      max_tokens;
      max_input_tokens;
      max_cost_usd;
      temperature;
      max_idle_turns;
      stream_idle_timeout_s;
      guardrails;
      hooks;
      context_reducer;
      memory;
      tool_retry_policy;
      enable_thinking;
      contract;
      description;
      compact_ratio;
      approval;
    }

let argv_prompt_arg_limit_bytes = 512 * 1024
let argv_prompt_min_retry_tokens = 4_096

type argv_prompt_preflight = {
  prompt_bytes : int;
  prompt_tokens : int;
  context_window_tokens : int;
  retry_limit_tokens : int;
  hits_argv_limit : bool;
  hits_context_window : bool;
}

let argv_prompt_bytes_to_token_limit ~prompt_bytes ~prompt_tokens =
  if prompt_bytes <= 0 then
    prompt_tokens
  else
    Int64.(
      div
        (mul (of_int (Stdlib.max 1 prompt_tokens))
           (of_int argv_prompt_arg_limit_bytes))
        (of_int prompt_bytes)
      |> to_int)

let argv_prompt_preflight ~(config : Cascade_runner.config) ~(goal : string)
    : argv_prompt_preflight option =
  (* RFC-0058 §2.4 — dispatch by adapter capability flag
     ([tool_policy.argv_prompt_preflight]), never by provider variant.
     Adding a vendor that needs this check is now a TOML/adapter registry
     change, not a call-site code change. *)
  let requires_preflight =
    match Provider_adapter.adapter_of_provider_config config.provider_cfg with
    | Some adapter -> adapter.tool_policy.argv_prompt_preflight
    | None -> false
  in
  if not requires_preflight then None
  else
    let messages =
      Agent_sdk.Agent_turn.prepare_messages
        ~messages:(config.initial_messages @ [ Agent_sdk.Types.user_msg goal ])
        ~context_reducer:config.context_reducer
        ~tiered_memory:None
        ~turn_params:Agent_sdk.Hooks.default_turn_params
        ()
    in
    let req_config =
      match String.trim config.system_prompt with
      | "" -> config.provider_cfg
      | _ -> { config.provider_cfg with system_prompt = Some config.system_prompt }
    in
    let system_prompt =
      Llm_provider.Cli_common_prompt.system_prompt_of ~req_config messages
    in
    let prompt =
      messages
      |> Llm_provider.Cli_common_prompt.non_system_messages
      |> Llm_provider.Cli_common_prompt.prompt_of_messages
      |> fun prompt ->
      Llm_provider.Cli_common_prompt.prompt_with_system_prompt
        ~prompt ~system_prompt
    in
    let prompt_bytes = String.length prompt in
    let prompt_tokens =
      max 1 (Agent_sdk.Context_reducer.estimate_char_tokens prompt)
    in
    let context_window_tokens =
      Agent_sdk.Provider.resolve_max_context_tokens
        ~fallback:Cascade_runtime.fallback_context_window
        (Some config.provider)
    in
    let hits_argv_limit = prompt_bytes > argv_prompt_arg_limit_bytes in
    let hits_context_window = prompt_tokens > context_window_tokens in
    if not hits_argv_limit && not hits_context_window then
      None
    else
      let retry_limit_tokens =
        let byte_limit =
          argv_prompt_bytes_to_token_limit ~prompt_bytes ~prompt_tokens
        in
        let limit =
          if hits_argv_limit then byte_limit else prompt_tokens
          |> fun limit ->
          if hits_context_window then min context_window_tokens limit else limit
        in
        max argv_prompt_min_retry_tokens (min prompt_tokens limit)
      in
      Some
        {
          prompt_bytes;
          prompt_tokens;
          context_window_tokens;
          retry_limit_tokens;
          hits_argv_limit;
          hits_context_window;
        }

let argv_prompt_preflight_error ~(scope : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (preflight : argv_prompt_preflight) =
  Log.Misc.warn
    "argv prompt preflight rejected spawn (scope=%s, provider_kind=%s, model=%s, prompt_bytes=%d, prompt_tokens=%d, retry_limit=%d, context_window=%d, argv_limit=%b, context_limit=%b)"
    scope
    (Llm_provider.Provider_config.string_of_provider_kind provider_cfg.kind)
    provider_cfg.model_id preflight.prompt_bytes
    preflight.prompt_tokens preflight.retry_limit_tokens
    preflight.context_window_tokens preflight.hits_argv_limit
    preflight.hits_context_window;
  Agent_sdk.Error.Agent
    (Agent_sdk.Error.TokenBudgetExceeded
       {
         kind = "Input";
         used = preflight.prompt_tokens;
         limit = preflight.retry_limit_tokens;
       })

let with_argv_prompt_preflight ~(scope : string) ~(config : Cascade_runner.config)
    ~(goal : string) (run : unit -> ('a, Agent_sdk.Error.sdk_error) result)
    : ('a, Agent_sdk.Error.sdk_error) result =
  match argv_prompt_preflight ~config ~goal with
  | Some preflight ->
    Error
      (argv_prompt_preflight_error ~scope ~provider_cfg:config.provider_cfg
         preflight)
  | None -> run ()
