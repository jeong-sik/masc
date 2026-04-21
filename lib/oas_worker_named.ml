(** Oas_worker_named — MASC named-cascade and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named cascade
    profiles ([run_named])
    or explicit model label ([run_model_by_label]), with optional MASC
    tool bridging variants.

    @since God file decomposition — extracted from oas_worker.ml *)

open Result.Syntax

(* ================================================================ *)
(* Cascade profile defaults (moved from Cascade module)              *)
(* ================================================================ *)

let default_config_path = Cascade_runtime.cascade_config_path
let default_model_strings = Cascade_runtime.default_model_strings

(* ================================================================ *)
(* Named model execution                                            *)
(* ================================================================ *)

let require_eio ?sw ?net () =
  let sw = match sw with Some s -> Some s | None -> Eio_context.get_switch_opt () in
  let net = match net with Some n -> Some n | None -> Eio_context.get_net_opt () in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

let eio_context_error_to_sdk_error detail =
  Oas.Error.Config
    (Oas.Error.InvalidConfig { field = "eio_context"; detail })

let cascade_catalog_error_to_sdk_error detail =
  Oas.Error.Config
    (Oas.Error.InvalidConfig { field = "cascade_name"; detail })

(** Resolve cascade provider configs via MASC Cascade_config.
    Returns Provider_config.t list for the downstream OAS runtime,
    bypassing the old Model_spec facade. *)
let resolve_cascade_providers ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ~cascade_name () =
  Cascade_runtime.resolve_named_providers_result ?provider_filter
    ~require_tool_choice_support ~require_tool_support ~cascade_name ()

(** Resolve from an explicit model string list (user-declared in keeper TOML).
    MASC parses the strings via its local [Cascade_config] and passes the
    resulting provider configs into OAS execution. *)
let resolve_providers_from_model_strings ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    model_strings =
  Cascade_runtime.resolve_providers_from_model_strings ?provider_filter
    ~require_tool_choice_support ~require_tool_support model_strings

type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : string;
      reason : Keeper_types.cascade_exhaustion_reason;
    }
  | No_tool_capable_provider of {
      cascade_name : string;
      configured_labels : string list;
    }
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason : string;
    }
  | Admission_queue_timeout of {
      keeper_name : string;
      cascade_name : string;
      wait_sec : float;
    }
  | Turn_timeout of {
      elapsed_sec : float;
    }
  | Ambiguous_post_commit of {
      is_timeout : bool;
      tools : string list;
      original_error : string;
    }

let masc_internal_error_prefix = "[masc_oas_error] "

let string_opt_of_assoc key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let masc_internal_error_to_json = function
  | Cascade_exhausted { cascade_name; reason } ->
    `Assoc
      [
        ("kind", `String "cascade_exhausted");
        ("cascade_name", `String cascade_name);
        ("reason", Keeper_types.cascade_exhaustion_reason_to_json reason);
      ]
  | No_tool_capable_provider { cascade_name; configured_labels } ->
    `Assoc
      [
        ("kind", `String "no_tool_capable_provider");
        ("cascade_name", `String cascade_name);
        ( "configured_labels",
          `List (List.map (fun value -> `String value) configured_labels) );
      ]
  | Accept_rejected { scope; model; reason } ->
    `Assoc
      [
        ("kind", `String "accept_rejected");
        ("scope", `String scope);
        ("model", Json_util.string_opt_to_json model);
        ("reason", `String reason);
      ]
  | Admission_queue_timeout { keeper_name; cascade_name; wait_sec } ->
    `Assoc
      [
        ("kind", `String "admission_queue_timeout");
        ("keeper_name", `String keeper_name);
        ("cascade_name", `String cascade_name);
        ("wait_sec", `Float wait_sec);
      ]
  | Turn_timeout { elapsed_sec } ->
    `Assoc
      [
        ("kind", `String "turn_timeout");
        ("elapsed_sec", `Float elapsed_sec);
      ]
  | Ambiguous_post_commit { is_timeout; tools; original_error } ->
    `Assoc
      [
        ("kind", `String "ambiguous_post_commit");
        ("is_timeout", `Bool is_timeout);
        ("tools", `List (List.map (fun v -> `String v) tools));
        ("original_error", `String original_error);
      ]

let sdk_error_of_masc_internal_error err =
  Oas.Error.Internal
    (masc_internal_error_prefix ^ Yojson.Safe.to_string (masc_internal_error_to_json err))

let admission_wait_timeout_error
    ~(keeper_name : string)
    ~(cascade_name : string)
    ~(priority : Llm_provider.Request_priority.t)
    (wait_ms : int) =
  let wait_sec = float_of_int wait_ms /. 1000.0 in
  let msg =
    Printf.sprintf
      "Admission queue wait timeout after %.1fs (wait_ms=%d, keeper=%s, cascade=%s, priority=%s)"
      wait_sec wait_ms keeper_name cascade_name
      (Llm_provider.Request_priority.to_string priority)
  in
  Log.Misc.warn "%s" msg;
  Error
    (sdk_error_of_masc_internal_error
       (Admission_queue_timeout { keeper_name; cascade_name; wait_sec }))

let classify_masc_internal_error (err : Oas.Error.sdk_error) :
    masc_internal_error option =
  match err with
  | Oas.Error.Internal msg when String.starts_with ~prefix:masc_internal_error_prefix msg ->
    let payload =
      String.sub msg
        (String.length masc_internal_error_prefix)
        (String.length msg - String.length masc_internal_error_prefix)
    in
    (try
       match Yojson.Safe.from_string payload with
       | `Assoc fields as json -> (
           match List.assoc_opt "kind" fields with
           | Some (`String "cascade_exhausted") -> (
               match string_opt_of_assoc "cascade_name" json with
               | Some cascade_name ->
                 let reason =
                   match List.assoc_opt "reason" (match json with `Assoc fields -> fields | _ -> []) with
                   | Some json_val ->
                       (match Keeper_types.cascade_exhaustion_reason_of_json json_val with
                        | Some r -> r
                        | None -> Other_detail "unknown_cascade_reason")
                   | None -> Other_detail "missing_reason_field"
                 in
                 Some
                   (Cascade_exhausted
                      {
                        cascade_name;
                        reason;
                      })
               | None -> None)
           | Some (`String "no_tool_capable_provider") -> (
               match string_opt_of_assoc "cascade_name" json with
               | Some cascade_name ->
                 let configured_labels =
                   match json with
                   | `Assoc fields -> (
                       match List.assoc_opt "configured_labels" fields with
                       | Some (`List values) ->
                         values
                         |> List.filter_map (function
                              | `String value -> Some value
                              | _ -> None)
                       | _ -> [])
                   | _ -> []
                 in
                 Some
                   (No_tool_capable_provider
                      {
                        cascade_name;
                        configured_labels;
                      })
               | None -> None)
           | Some (`String "accept_rejected") -> (
               match string_opt_of_assoc "scope" json, string_opt_of_assoc "reason" json with
               | Some scope, Some reason ->
                 Some
                   (Accept_rejected
                      {
                        scope;
                        model = string_opt_of_assoc "model" json;
                        reason;
                      })
               | _ -> None)
           | Some (`String "admission_queue_timeout") -> (
               match string_opt_of_assoc "keeper_name" json,
                     string_opt_of_assoc "cascade_name" json
               with
               | Some keeper_name, Some cascade_name ->
                 let wait_sec =
                   match json with
                   | `Assoc fields -> (
                       match List.assoc_opt "wait_sec" fields with
                       | Some (`Float v) -> v
                       | _ -> 0.0)
                   | _ -> 0.0
                 in
                 Some (Admission_queue_timeout { keeper_name; cascade_name; wait_sec })
               | _ -> None)
           | Some (`String "turn_timeout") -> (
               match json with
               | `Assoc fields -> (
                   match List.assoc_opt "elapsed_sec" fields with
                   | Some (`Float v) ->
                     Some (Turn_timeout { elapsed_sec = v })
                   | _ -> None)
               | _ -> None)
           | Some (`String "ambiguous_post_commit") -> (
               match string_opt_of_assoc "original_error" json with
               | Some original_error ->
                 let is_timeout =
                   match json with
                   | `Assoc fields -> (
                       match List.assoc_opt "is_timeout" fields with
                       | Some (`Bool b) -> b
                       | _ -> false)
                   | _ -> false
                 in
                 let tools =
                   match json with
                   | `Assoc fields -> (
                       match List.assoc_opt "tools" fields with
                       | Some (`List values) ->
                         values
                         |> List.filter_map (function
                              | `String value -> Some value
                              | _ -> None)
                       | _ -> [])
                   | _ -> []
                 in
                 Some (Ambiguous_post_commit { is_timeout; tools; original_error })
               | _ -> None)
           | _ -> None)
       | _ -> None
     with Yojson.Json_error _ -> None)
  | _ -> None

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
    () : (Oas_worker_exec.config, Oas.Error.sdk_error) result =
  let* provider =
    Oas_worker_exec.resolve_provider_config_of_label model_label
    |> Result.map_error Oas_worker_exec.label_resolution_error_to_sdk_error
  in
  Ok
    {
      (Oas_worker_exec.default_config ~name ~provider_cfg:provider
         ~system_prompt ~tools)
      with
      max_turns;
      max_tokens;
      max_input_tokens;
      max_cost_usd;
      temperature;
      max_idle_turns;
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

let codex_cli_prompt_arg_limit_bytes = 512 * 1024
let codex_cli_min_retry_tokens = 4_096

type codex_cli_prompt_preflight = {
  prompt_bytes : int;
  prompt_tokens : int;
  context_window_tokens : int;
  retry_limit_tokens : int;
  hits_argv_limit : bool;
  hits_context_window : bool;
}

let codex_cli_prompt_bytes_to_token_limit ~prompt_bytes ~prompt_tokens =
  if prompt_bytes <= 0 then
    prompt_tokens
  else
    Int64.(
      div
        (mul (of_int (Stdlib.max 1 prompt_tokens))
           (of_int codex_cli_prompt_arg_limit_bytes))
        (of_int prompt_bytes)
      |> to_int)

let codex_cli_prompt_preflight ~(config : Oas_worker_exec.config) ~(goal : string)
    : codex_cli_prompt_preflight option =
  match config.provider_cfg.kind with
  | Llm_provider.Provider_config.Codex_cli ->
    let messages =
      Oas.Agent_turn.prepare_messages
        ~messages:(config.initial_messages @ [ Oas.Types.user_msg goal ])
        ~context_reducer:config.context_reducer
        ~tiered_memory:None
        ~turn_params:Oas.Hooks.default_turn_params
    in
    let req_config =
      match String.trim config.system_prompt with
      | "" -> config.provider_cfg
      | _ ->
        { config.provider_cfg with
          system_prompt = Some config.system_prompt;
        }
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
      max 1 (Oas.Context_reducer.estimate_char_tokens prompt)
    in
    let context_window_tokens =
      Oas.Provider.resolve_max_context_tokens
        ~fallback:Cascade_runtime.fallback_context_window
        (Some config.provider)
    in
    let hits_argv_limit = prompt_bytes > codex_cli_prompt_arg_limit_bytes in
    let hits_context_window = prompt_tokens > context_window_tokens in
    if not hits_argv_limit && not hits_context_window then
      None
    else
      let retry_limit_tokens =
        let byte_limit =
          codex_cli_prompt_bytes_to_token_limit ~prompt_bytes ~prompt_tokens
        in
        let limit =
          if hits_argv_limit then byte_limit else prompt_tokens
          |> fun limit ->
          if hits_context_window then min context_window_tokens limit else limit
        in
        max codex_cli_min_retry_tokens (min prompt_tokens limit)
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
  | _ -> None

let codex_cli_preflight_error ~(scope : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (preflight : codex_cli_prompt_preflight) =
  Log.Misc.warn
    "codex_cli prompt preflight rejected spawn (scope=%s, model=%s, prompt_bytes=%d, prompt_tokens=%d, retry_limit=%d, context_window=%d, argv_limit=%b, context_limit=%b)"
    scope provider_cfg.model_id preflight.prompt_bytes
    preflight.prompt_tokens preflight.retry_limit_tokens
    preflight.context_window_tokens preflight.hits_argv_limit
    preflight.hits_context_window;
  Oas.Error.Agent
    (Oas.Error.TokenBudgetExceeded
       {
         kind = "Input";
         used = preflight.prompt_tokens;
         limit = preflight.retry_limit_tokens;
       })

let with_codex_cli_preflight ~(scope : string) ~(config : Oas_worker_exec.config)
    ~(goal : string) (run : unit -> ('a, Oas.Error.sdk_error) result)
    : ('a, Oas.Error.sdk_error) result =
  match codex_cli_prompt_preflight ~config ~goal with
  | Some preflight ->
    Error (codex_cli_preflight_error ~scope ~provider_cfg:config.provider_cfg preflight)
  | None -> run ()

(** Convert an OAS sdk_error into a Cascade_fsm provider_outcome.
    API-level errors and model-capability-dependent agent errors are
    cascadeable (a different provider may succeed).  Structural agent
    errors (budget, idle, exit) are not — they would recur on any model. *)
let sdk_error_to_cascade_outcome (err : Oas.Error.sdk_error)
    : Cascade_fsm.provider_outcome option =
  match err with
  | Oas.Error.Api api_err ->
    let http_err = match api_err with
      | Llm_provider.Retry.InvalidRequest { message } ->
        Llm_provider.Http_client.HttpError { code = 400; body = message }
      | Llm_provider.Retry.ContextOverflow { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 400; body = message }
      | Llm_provider.Retry.RateLimited { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 429; body = message }
      | Llm_provider.Retry.ServerError { status; message } ->
        Llm_provider.Http_client.HttpError { code = status; body = message }
      | Llm_provider.Retry.AuthError { message } ->
        Llm_provider.Http_client.HttpError { code = 401; body = message }
      | Llm_provider.Retry.Overloaded { message } ->
        Llm_provider.Http_client.HttpError { code = 529; body = message }
      | Llm_provider.Retry.NetworkError { message }
      | Llm_provider.Retry.Timeout { message } ->
        Llm_provider.Http_client.NetworkError { message }
    in
    Some (Cascade_fsm.Call_err http_err)
  (* Model-capability errors: the next provider may handle these.
     CompletionContractViolation: model returned text when tool_use was
     required — a different model with better tool calling may succeed.
     UnrecognizedStopReason: model returned a non-standard stop reason
     that this provider does not map — another provider may not. *)
  | Oas.Error.Agent (Oas.Error.CompletionContractViolation { reason; _ }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | Oas.Error.Agent (Oas.Error.UnrecognizedStopReason { reason }) ->
    Some (Cascade_fsm.Call_err
      (Llm_provider.Http_client.AcceptRejected { reason }))
  | _ -> None

let moonshot_auth_hint_marker = "Moonshot returned 401"
let openai_compat_not_found_hint_marker =
  "OpenAI-compatible endpoint returned 404"

let is_moonshot_provider (provider_cfg : Llm_provider.Provider_config.t) =
  String_util.contains_substring_ci provider_cfg.base_url "moonshot.ai"
  || String.starts_with ~prefix:"kimi" provider_cfg.model_id

let resolve_kimi_api_key_env_name ~cascade_name =
  let fallback_env = "MOONSHOT_API_KEY" in
  let resolve_from_overrides overrides =
    let find_non_empty key =
      match List.assoc_opt key overrides with
      | Some value when String.trim value <> "" -> Some value
      | _ -> None
    in
    match find_non_empty "kimi" with
    | Some env_name -> env_name
    | None ->
      (match find_non_empty "*" with
       | Some env_name -> env_name
       | None -> fallback_env)
  in
  match default_config_path () with
  | Some config_path ->
    let overrides =
      Cascade_config.resolve_api_key_env ~config_path ~name:cascade_name
    in
    resolve_from_overrides overrides
  | None -> fallback_env

let enrich_sdk_error ~cascade_name
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (err : Oas.Error.sdk_error) =
  let append_hint message hint_marker detail =
    if String_util.contains_substring_ci message hint_marker then
      message
    else
      Printf.sprintf "%s (%s: %s)" message hint_marker detail
  in
  match err with
  | Oas.Error.Api (Llm_provider.Retry.AuthError { message })
    when is_moonshot_provider provider_cfg ->
    let env_name =
      match resolve_kimi_api_key_env_name ~cascade_name with
      | "" -> "configured kimi API key env"
      | value -> value
    in
    let detail =
      if String.trim provider_cfg.api_key = "" then
        Printf.sprintf "%s is empty or unset in this process" env_name
      else
        Printf.sprintf
          "%s was loaded and the auth header was populated; verify that it is a valid Moonshot API key"
          env_name
    in
    Oas.Error.Api
      (Llm_provider.Retry.AuthError
         {
           message =
             append_hint message moonshot_auth_hint_marker detail;
         })
  | Oas.Error.Api (Llm_provider.Retry.InvalidRequest { message })
    when provider_cfg.kind = Llm_provider.Provider_config.OpenAI_compat
         && String_util.contains_substring_ci message "not found" ->
    let detail =
      Printf.sprintf "base_url=%s request_path=%s endpoint=%s"
        provider_cfg.base_url provider_cfg.request_path
        (provider_cfg.base_url ^ provider_cfg.request_path)
    in
    Oas.Error.Api
      (Llm_provider.Retry.InvalidRequest
         {
           message =
             append_hint message openai_compat_not_found_hint_marker detail;
         })
  | _ -> err

let cli_wrapped_hard_quota_indicators = [
  "terminalquotaerror";
  "quota_exhausted";
  "exhausted your capacity on this model";
  "quota will reset after";
]

let message_looks_like_cli_wrapped_hard_quota (message : string) : bool =
  List.exists
    (String_util.contains_substring_ci message)
    cli_wrapped_hard_quota_indicators

let sdk_error_is_hard_quota (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api api_err ->
    Llm_provider.Retry.is_hard_quota api_err
    ||
    (match api_err with
     | Llm_provider.Retry.NetworkError { message }
     | Llm_provider.Retry.Overloaded { message }
     | Llm_provider.Retry.ServerError { message; _ } ->
       message_looks_like_cli_wrapped_hard_quota message
     | Llm_provider.Retry.RateLimited _
     | Llm_provider.Retry.AuthError _
     | Llm_provider.Retry.InvalidRequest _
     | Llm_provider.Retry.ContextOverflow _
     | Llm_provider.Retry.Timeout _ ->
       false)
  | _ -> false

(** Run a single Agent.run() call with MASC-driven cascade model fallback.

    MASC drives the cascade FSM directly:
    - Resolves cascade providers from cascade.json
    - For each provider, runs OAS with a single provider
    - Uses Cascade_fsm.decide to determine next action on failure
    - Cascade loop runs inside Admission_queue permit

    @param accept Optional response validator. Default accepts all.
    @since Phase 2 — MASC-driven cascade FSM *)
let run_named
    ~cascade_name
    ?(keeper_name = "")
    ?model_strings
    ~goal
    ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?priority
    ?session_id
    ?(system_prompt = "")
    ?(tools = [])
    ?(initial_messages = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?(accept = fun (_ : Oas_response.api_response) -> true)
    ?guardrails
    ?hooks
    ?context_reducer
    ?memory
    ?tool_retry_policy
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?agent_ref
    ?proof_ref
    ?contract
    ?transport
    ?cli_transport_overrides
    ?(allowed_paths = [])
    ?checkpoint_sidecar
    ?(cache_system_prompt = false)
    ?(yield_on_tool = false)
    ?compact_ratio
    ?checkpoint_dir
    ?context_injector
    ?context
    ?slot_id
    ?enable_thinking
    ?approval
    ?exit_condition
    ?exit_condition_result
    ?summarizer
    ?oas_checkpoint
    ?event_bus
    ?sw
    ?net
    ()
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
  let cascade_name =
    Keeper_cascade_profile.normalize_declared_name cascade_name
  in
  let configured_labels_result, candidate_cfgs_result =
    match model_strings with
    | Some ms when ms <> [] ->
      (* Direct model strings from keeper TOML — skip named preset lookup.
         MASC passes these strings through without interpretation. *)
      ( Ok ms,
        Ok
          (resolve_providers_from_model_strings ?provider_filter
             ~require_tool_choice_support ~require_tool_support ms) )
    | _ ->
      ( Cascade_runtime.models_of_cascade_name_result cascade_name,
        resolve_cascade_providers ?provider_filter
          ~require_tool_choice_support ~require_tool_support ~cascade_name ()
      )
  in
  (match configured_labels_result, candidate_cfgs_result with
   | Error detail, _ | _, Error detail ->
       Log.Misc.error "cascade %s: %s" cascade_name detail;
       Error (cascade_catalog_error_to_sdk_error detail)
   | Ok configured_labels, Ok candidate_cfgs ->
  let capture, _metrics = Oas_worker_cascade.cascade_metrics_for_candidates ~candidate_cfgs () in
  let name = Printf.sprintf "oas-%s" cascade_name in
  match candidate_cfgs with
  | [] ->
      Log.Misc.error "cascade %s: no callable models available" cascade_name;
      Error
      (sdk_error_of_masc_internal_error
         (if require_tool_choice_support then
            No_tool_capable_provider
              {
                cascade_name;
                configured_labels;
              }
          else
            Cascade_exhausted
              {
                cascade_name;
                reason = Keeper_types.No_providers_available;
              }))
  | _ ->
  let transport_resolved = match transport with
    | Some t -> t
    | None -> Masc_grpc_transport.from_env ()
  in
  let queue_priority =
    Option.value priority ~default:Llm_provider.Request_priority.Proactive
  in
  (* MASC-driven cascade FSM: try each provider, decide on failure.
     Mid-turn resume: when a provider fails after completing some turns,
     the next provider resumes from the failed agent's checkpoint instead
     of restarting from scratch.

     Immutable checkpoint threading: try_provider returns both the result
     and the agent's checkpoint (if progress was made). try_cascade
     threads this checkpoint to the next provider without mutable state. *)
  let try_provider ?resume_checkpoint (provider_cfg : Llm_provider.Provider_config.t) =
    let config_result =
      Oas_worker_exec.resolve_tool_lane_for_oas_tools ~provider_cfg ~tools
      |> Result.map
           (fun (effective_tools, runtime_mcp_policy) ->
             {
               (Oas_worker_exec.default_config ~name ~provider_cfg
                  ~system_prompt ~tools:effective_tools)
               with
                 priority;
                 max_turns;
                 max_tokens;
                 max_input_tokens;
                 max_cost_usd;
                 temperature;
                 max_idle_turns;
                 guardrails;
                 hooks;
                 context_reducer;
                 memory;
                 tool_retry_policy;
                 description =
                   Some
                     (Printf.sprintf "cascade:%s/%s" cascade_name
                        provider_cfg.model_id);
                 transport = transport_resolved;
                 allowed_paths;
                 checkpoint_sidecar;
                 session_id;
                 cache_system_prompt;
                 compact_ratio;
                 contract;
                 checkpoint_dir;
                 context_injector;
                 context;
                 slot_id;
                 enable_thinking;
                 event_bus;
                 approval;
                 exit_condition;
                 exit_condition_result;
                 summarizer;
                 initial_messages;
                 raw_trace;
                 yield_on_tool;
                 runtime_mcp_policy;
                 cli_transport_overrides;
             })
    in
    let local_agent_ref : Oas.Agent.t option ref = ref None in
    match config_result with
    | Error err ->
      (Error err, None)
    | Ok config ->
      match
        with_codex_cli_preflight
          ~scope:(Printf.sprintf "cascade:%s/%s" cascade_name provider_cfg.model_id)
          ~config ~goal
          (fun () ->
            let effective_checkpoint = match resume_checkpoint with
              | Some _ -> resume_checkpoint
              | None -> oas_checkpoint
            in
            let result =
              Oas_worker_exec.run ~sw ~net ~config
                ?oas_checkpoint:effective_checkpoint ?on_event
                ?on_yield ?on_resume ~agent_ref:local_agent_ref ?proof_ref
                ?contract goal
            in
            Ok result)
    with
    | Error err ->
      (Error err, None)
    | Ok result ->
      let result =
        Result.map_error
          (enrich_sdk_error ~cascade_name ~provider_cfg)
          result
      in
      (* Extract checkpoint from the agent if it made progress.
         The agent's mutable state reflects all completed turns even on Error. *)
      let checkpoint_after = match !local_agent_ref with
        | Some agent when (Oas.Agent.state agent).turn_count > 0 ->
          (* Also propagate to caller's agent_ref for final result *)
          (match agent_ref with Some r -> r := Some agent | None -> ());
          Some (Oas.Agent.checkpoint agent)
        | Some agent ->
          (match agent_ref with Some r -> r := Some agent | None -> ());
          None
        | None -> None
      in
      (result, checkpoint_after)
  in
  let rec try_cascade
      ?(on_success = fun ~provider_key:_ -> ())
      ?resume_checkpoint remaining last_err =
    match remaining with
    | [] ->
      let reason : Keeper_types.cascade_exhaustion_reason = match last_err with
        | Some (Llm_provider.Http_client.NetworkError { message })
          when String_util.contains_substring_ci message "connection refused" ->
            Keeper_types.Connection_refused
        | Some (Llm_provider.Http_client.HttpError { code; body }) ->
            Keeper_types.Other_detail
              (Printf.sprintf "HTTP %d: %s" code
                (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." body |> String_util.to_string))
        | Some (Llm_provider.Http_client.AcceptRejected { reason = r }) ->
            Keeper_types.Other_detail r
        | Some (Llm_provider.Http_client.CliTransportRequired { kind }) ->
            Keeper_types.Other_detail
              (Printf.sprintf "%s provider requires a CLI transport" kind)
        | Some (Llm_provider.Http_client.NetworkError { message }) ->
            Keeper_types.Other_detail message
        | None -> Keeper_types.No_providers_available
      in
      let observation =
        Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
          ~candidate_cfgs ~selected_model_raw:None ~capture
      in
      Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
      Error
        (sdk_error_of_masc_internal_error
           (Cascade_exhausted
              {
                cascade_name;
                reason;
              }))
    | (provider_cfg : Llm_provider.Provider_config.t) :: rest ->
      let is_last = rest = [] in
      Log.Misc.debug "cascade %s: trying %s (is_last=%b)" cascade_name provider_cfg.model_id is_last;
      let (result, checkpoint_after) = try_provider ?resume_checkpoint provider_cfg in
      (* Thread checkpoint forward: if this provider made progress,
         the next provider can resume from where this one left off. *)
      let next_resume = match checkpoint_after with
        | Some _ -> checkpoint_after
        | None -> resume_checkpoint
      in
      (* Track provider call outcome for weighted-routing health.
         Semantics: response arrived = provider healthy (even if accept
         logic later rejects); error = provider unhealthy.  The
         cascade-decision branches (Accept_on_exhaustion / Try_next /
         Exhausted) are orthogonal to provider health. *)
      (match result with
      | Ok result when accept result.response ->
        Cascade_health_tracker.(record_success global ~provider_key:provider_cfg.model_id);
        (* FSM: Call_ok → Accept *)
        let observation =
          Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
            ~candidate_cfgs ~selected_model_raw:(Some result.response.model) ~capture
        in
        let result = { result with cascade_observation = Some observation } in
        Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
        on_success ~provider_key:provider_cfg.model_id;
        Ok result
      | Ok result ->
        (* Response arrived but failed the cascade's [accept] predicate
           (empty body, schema gate, etc.).  Prior to 0.160.0 this
           called [record_success] on the rationale that "the provider
           answered"; that masked gate drift because provider health
           stayed 100% while every call fell through to the next tier.
           [record_rejected] behaves like a failure for cooldown /
           weight but keeps the [Rejected] tag so the dashboard can
           distinguish it from hard errors. *)
        Cascade_health_tracker.(record_rejected global ~provider_key:provider_cfg.model_id);
        (* FSM: Accept_rejected → decide *)
        let reason = Printf.sprintf "response rejected by accept (model=%s)" result.response.model in
        let outcome = Cascade_fsm.Accept_rejected
          { response = result.response; reason } in
        (match Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome with
         | Cascade_fsm.Accept_on_exhaustion { response; _ } ->
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some response.model) ~capture
           in
           let result = { result with cascade_observation = Some observation } in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
           on_success ~provider_key:provider_cfg.model_id;
           Ok result
         | Cascade_fsm.Try_next { last_err = new_err } ->
           (* Demoted from WARN to INFO (task-239): cascade will retry the
              next tier.  Tagged [cascade-fallback] so dashboard filters
              can distinguish recovery-in-progress from hard failures. *)
           Log.Misc.info "[cascade-fallback] cascade %s: accept rejected %s (%s), trying next" cascade_name provider_cfg.model_id reason;
           Oas_worker_cascade.record_fallback_event capture ~candidate_cfgs
             ~from_model:provider_cfg.model_id ~to_model:"next" ~reason;
           try_cascade ?resume_checkpoint:next_resume rest new_err
         | Cascade_fsm.Exhausted _ ->
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some result.response.model) ~capture
           in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Rejected ~observation:(Some observation);
           Log.Misc.error "cascade %s exhausted: all tiers rejected by accept predicate (last model=%s, reason=%s)"
             cascade_name result.response.model reason;
           Error
             (sdk_error_of_masc_internal_error
                (Accept_rejected
                   {
                     scope = cascade_name;
                     model = Some result.response.model;
                     reason;
                   }))
         | Cascade_fsm.Accept resp ->
           (* Should be unreachable with accept_on_exhaustion:false, but handle gracefully *)
           Log.Misc.warn "cascade %s: unexpected Accept in Accept_rejected branch (model=%s)" cascade_name resp.model;
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some resp.model) ~capture
           in
           let result = { result with cascade_observation = Some observation } in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
           on_success ~provider_key:provider_cfg.model_id;
           Ok result)
      | Error sdk_err ->
        (* Classify hard-quota (account-level exhaustion) distinctly from
           transient failures.  Hard quota (e.g. Anthropic multi-day usage
           limit, ZAI balance 0) will not recover within the 60s
           [cooldown_sec]; apply an immediate long cooldown
           ([hard_quota_cooldown_sec], default 1h) so weighted_random
           re-selection doesn't waste cascade turns on a provider that
           is terminally unavailable. *)
        if sdk_error_is_hard_quota sdk_err then
          Cascade_health_tracker.(record_hard_quota global ~provider_key:provider_cfg.model_id)
        else
          Cascade_health_tracker.(record_failure global ~provider_key:provider_cfg.model_id);
        (* FSM: Call_err → decide *)
        (match sdk_error_to_cascade_outcome sdk_err with
         | Some outcome ->
           (match Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome with
            | Cascade_fsm.Try_next { last_err = new_err } ->
              (* Demoted from WARN to INFO (task-239): cascade will retry
                 the next tier.  Tagged [cascade-fallback] so dashboards
                 and log filters can distinguish recovery-in-progress
                 from hard failures.  The exec layer's per-tier
                 "agent errored" log was also demoted to DEBUG in the
                 same change, so this INFO is the canonical per-tier
                 signal. *)
              Log.Misc.info "[cascade-fallback] cascade %s: %s failed (%s), trying next" cascade_name provider_cfg.model_id (Oas.Error.to_string sdk_err);
              Oas_worker_cascade.record_fallback_event capture ~candidate_cfgs
                ~from_model:provider_cfg.model_id ~to_model:"next"
                ~reason:(Oas.Error.to_string sdk_err);
              try_cascade ?resume_checkpoint:next_resume rest new_err
            | Cascade_fsm.Exhausted _ ->
              let observation =
                Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
                  ~candidate_cfgs ~selected_model_raw:None ~capture
              in
              Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
              Log.Misc.error "cascade %s exhausted: all tiers failed (last model=%s, error=%s)"
                cascade_name provider_cfg.model_id (Oas.Error.to_string sdk_err);
              Error sdk_err
            | _ -> Error sdk_err)
         | None ->
           (* Non-API error (agent, config, etc.) — not cascadeable *)
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name ~configured_labels
               ~candidate_cfgs ~selected_model_raw:None ~capture
           in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
           Log.Misc.error "cascade %s: non-cascadable error from %s: %s"
             cascade_name provider_cfg.model_id (Oas.Error.to_string sdk_err);
           Error sdk_err))
  in
  (* Pluggable strategy + cycle/backoff wrapper (since 0.9.6).

     When no [<name>_strategy] is configured in cascade.json,
     [Cascade_config.resolve_strategy] returns [Cascade_strategy.failover]
     with [max_cycles = 1].  In that case [cycle_loop] invokes
     [try_cascade] exactly once on the original [candidate_cfgs] —
     bit-identical to the pre-strategy behaviour (linear failover). *)
  let* strategy =
    match Cascade_catalog_runtime.resolve_strategy ~name:cascade_name () with
    | Ok strategy -> Ok strategy
    | Error detail ->
        Log.Misc.error "cascade %s: %s" cascade_name detail;
        Error (cascade_catalog_error_to_sdk_error detail)
  in
  let* ollama_max =
    match
      Cascade_catalog_runtime.resolve_ollama_max_concurrent ~name:cascade_name ()
    with
    | Ok value -> Ok value
    | Error detail ->
        Log.Misc.error "cascade %s: %s" cascade_name detail;
        Error (cascade_catalog_error_to_sdk_error detail)
  in
  let* cli_max =
    match Cascade_catalog_runtime.resolve_cli_max_concurrent ~name:cascade_name () with
    | Ok value -> Ok value
    | Error detail ->
        Log.Misc.error "cascade %s: %s" cascade_name detail;
        Error (cascade_catalog_error_to_sdk_error detail)
  in
  let candidate_base_urls =
    List.map (fun (c : Llm_provider.Provider_config.t) -> c.base_url) candidate_cfgs
  in
  (* CLI providers have an empty [base_url]. Map them to a stable
     per-kind sentinel so the strategy's capacity probe and the
     client-capacity registry share the same lookup key. Delegates
     to the OAS SSOT {!Provider_kind.is_subprocess_cli}: any new CLI
     kind added to OAS (e.g. future Codex variants) is picked up
     automatically without touching this site. Sentinel format:
     ["cli:" ^ canonical-lowercase-name], matching
     {!Provider_kind.to_string}. *)
  let cli_sentinel_of_kind kind =
    if Llm_provider.Provider_config.is_subprocess_cli kind then
      Some ("cli:" ^ Llm_provider.Provider_config.string_of_provider_kind kind)
    else
      None
  in
  let capacity_key_of (c : Llm_provider.Provider_config.t) =
    if c.base_url <> "" then c.base_url
    else
      match cli_sentinel_of_kind c.kind with
      | Some s -> s
      | None -> ""
  in
  let candidate_capacity_keys = List.map capacity_key_of candidate_cfgs in
  (match ollama_max with
   | None ->
     Cascade_client_capacity.auto_register_for_candidates
       ~base_urls:candidate_base_urls
   | Some n ->
     Cascade_client_capacity.auto_register_ollama_with_override
       ~base_urls:candidate_base_urls ~max_concurrent:n);
  (* Refresh ollama [/api/ps] cache for any candidate that looks
     like ollama and whose cache entry has expired.  Failures are
     swallowed inside [Cascade_ollama_probe.try_probe] so a flaky
     probe never breaks the cascade — it just denies the cache
     optimisation for this attempt. *)
  Cascade_ollama_probe.refresh_many ~sw ~net candidate_base_urls;
  (match cli_max with
   | None ->
     Cascade_client_capacity.auto_register_cli_for_candidates
       ~capacity_keys:candidate_capacity_keys
   | Some n ->
     Cascade_client_capacity.auto_register_cli_with_override
       ~capacity_keys:candidate_capacity_keys ~max_concurrent:n);
  let adapter : Llm_provider.Provider_config.t Cascade_strategy.adapter = {
    health_key = (fun (c : Llm_provider.Provider_config.t) -> c.model_id);
    capacity_key = capacity_key_of;
    weight = (fun _ -> 1);
  } in
  let signal_ctx : Cascade_strategy.signal_ctx = {
    health = Cascade_health_tracker.global;
    capacity = (fun url ->
      match Cascade_throttle.capacity url with
      | Some _ as v -> v
      | None ->
        match Cascade_ollama_probe.cached_capacity url with
        | Some _ as v -> v
        | None -> Cascade_client_capacity.capacity url);
    now = Unix.gettimeofday ();
    rand_int = Random.int;
    keeper_name;
    cascade_name;
  } in
  let cycle_clock = Eio_context.get_clock_opt () in
  let do_backoff cycle =
    let ms = Cascade_strategy.backoff_ms strategy.cycle ~cycle in
    if ms <= 0 then ()
    else
      let secs = float_of_int ms /. 1000. in
      match cycle_clock with
      | Some clock -> Eio.Time.sleep clock secs
      | None ->
        (* No Eio clock available — skip backoff rather than block the
           thread.  Reachable only outside an Eio.Switch, which is not a
           supported entry path for this worker; the cycle simply
           continues without throttling. *)
        ()
  in
  let cascade_exhausted_after_filter ~cycle =
    let observation =
      Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
        ~configured_labels ~candidate_cfgs ~selected_model_raw:None ~capture
    in
    Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure
      ~observation:(Some observation);
    Error
      (sdk_error_of_masc_internal_error
         (Cascade_exhausted { cascade_name; reason = Keeper_types.Candidates_filtered_after_cycles }))
  in
  let record_trace ~cycle ~candidates_out ~backoff_ms ~kind =
    Cascade_strategy_trace.record {
      ts = Unix.gettimeofday ();
      cascade_name;
      strategy = Cascade_strategy.kind_to_string strategy.kind;
      cycle;
      candidates_in = List.length candidate_cfgs;
      candidates_out;
      backoff_ms;
      kind;
    }
  in
  let rec cycle_loop n =
    let ordered =
      Cascade_strategy.order_candidates strategy
        ~adapter ~ctx:signal_ctx ~cycle:n candidate_cfgs
    in
    let last_cycle = n + 1 >= strategy.cycle.max_cycles in
    match ordered with
    | [] when last_cycle ->
      record_trace ~cycle:n ~candidates_out:0 ~backoff_ms:0 ~kind:Exhausted;
      cascade_exhausted_after_filter ~cycle:n
    | [] ->
      let backoff = Cascade_strategy.backoff_ms strategy.cycle ~cycle:(n + 1) in
      record_trace ~cycle:n ~candidates_out:0 ~backoff_ms:backoff
        ~kind:Filtered_empty;
      Log.Misc.info
        "cascade %s: cycle %d (%s) filtered all candidates, retrying"
        cascade_name n (Cascade_strategy.kind_to_string strategy.kind);
      do_backoff (n + 1);
      cycle_loop (n + 1)
    | _ ->
      record_trace ~cycle:n ~candidates_out:(List.length ordered)
        ~backoff_ms:0 ~kind:Ordered;
      let on_success ~provider_key =
        Cascade_strategy.record_choice strategy ~ctx:signal_ctx ~provider_key
      in
      (match try_cascade ~on_success ordered None with
       | Ok _ as ok -> ok
       | Error _ as err when last_cycle -> err
       | Error _ ->
         Log.Misc.info
           "cascade %s: cycle %d exhausted, backoff before retry (strategy=%s)"
           cascade_name n (Cascade_strategy.kind_to_string strategy.kind);
         do_backoff (n + 1);
         cycle_loop (n + 1))
  in
  try
    Admission_queue.with_permit ?wait_timeout_sec
      ~priority:queue_priority ~keeper_name:name ~cascade_name
      (fun () -> cycle_loop 0)
  with
  | Admission_queue.Wait_timeout wait_ms ->
      admission_wait_timeout_error ~keeper_name:name ~cascade_name
        ~priority:queue_priority wait_ms)

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Validates the label parses before attempting execution. *)
let run_model_by_label
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?(accept = fun (_ : Oas_response.api_response) -> true)
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
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  let* config =
    config_for_label ~name:"oas-label-model" ~model_label ~system_prompt
      ~tools ~max_turns ~max_tokens ?max_input_tokens ?max_cost_usd ~temperature
      ~max_idle_turns ?guardrails ?hooks ?context_reducer ?memory
      ?tool_retry_policy
      ?enable_thinking
      ?compact_ratio
      ~description:(Some (Printf.sprintf "model_label:%s" model_label))
      ()
  in
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config = { config with transport = transport_resolved } in
      try
        Admission_queue.with_permit ?wait_timeout_sec
          ~priority:Llm_provider.Request_priority.Proactive
          ~keeper_name:"oas-label-model"
          ~cascade_name:model_label
          (fun () ->
            with_codex_cli_preflight
              ~scope:(Printf.sprintf "model_label:%s" model_label)
              ~config ~goal
              (fun () ->
                match Oas_worker_exec.run ~sw ~net ~config ?on_event ?contract goal with
                | Ok result when accept result.response -> Ok result
                | Ok result ->
                    Error
                      (sdk_error_of_masc_internal_error
                         (Accept_rejected
                            {
                              scope = model_label;
                              model = Some result.response.model;
                              reason =
                                Printf.sprintf
                                  "response rejected by accept (model=%s)"
                                  result.response.model;
                            }))
                | Error e -> Error e))
      with
      | Admission_queue.Wait_timeout wait_ms ->
          admission_wait_timeout_error ~keeper_name:"oas-label-model"
            ~cascade_name:model_label
            ~priority:Llm_provider.Request_priority.Proactive wait_ms

let run_named_with_masc_tools
    ~cascade_name
    ~goal
    ?priority
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
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
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  let oas_tools = List.map (fun (td : Types.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  run_named ~cascade_name ~goal ?priority ~system_prompt ~tools:oas_tools
    ~require_tool_support:(masc_tools <> [])
    ~max_turns ~temperature ~max_tokens ?max_input_tokens ?max_cost_usd
    ?wait_timeout_sec ?guardrails ?hooks ?memory
    ?tool_retry_policy
    ?compact_ratio
    ?approval
    ?raw_trace ?on_event ?on_yield ?on_resume ?proof_ref
    ?contract
    ?transport ~yield_on_tool ?sw ?net ()

let run_model_with_masc_tools
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
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
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  let* config =
    config_for_label ~name:"oas-explicit-model" ~model_label ~system_prompt
      ~tools:[] ~max_turns ~max_tokens ?max_input_tokens ?max_cost_usd ~temperature
      ?guardrails ?hooks ?memory ?tool_retry_policy ?enable_thinking
      ?compact_ratio
      ~description:(Some (Printf.sprintf "model_label:%s" model_label))
      ()
  in
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config = { config with raw_trace; transport = transport_resolved } in
      try
        Admission_queue.with_permit ?wait_timeout_sec
          ~priority:Llm_provider.Request_priority.Proactive
          ~keeper_name:"oas-explicit-model"
          ~cascade_name:model_label
          (fun () ->
            with_codex_cli_preflight
              ~scope:(Printf.sprintf "explicit_model:%s" model_label)
              ~config ~goal
              (fun () ->
                Oas_worker_exec.run_with_masc_tools ~sw ~net ~config ~masc_tools ~dispatch ?contract ?on_event
                  goal))
      with
      | Admission_queue.Wait_timeout wait_ms ->
          admission_wait_timeout_error ~keeper_name:"oas-explicit-model"
            ~cascade_name:model_label
            ~priority:Llm_provider.Request_priority.Proactive wait_ms
