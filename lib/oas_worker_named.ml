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
    ?runtime_mcp_policy
    ~cascade_name () =
  Cascade_runtime.resolve_named_providers_result ?provider_filter
    ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support ~cascade_name ()

(** Resolve from an explicit model string list (user-declared in keeper TOML).
    MASC parses the strings via its local [Cascade_config] and passes the
    resulting provider configs into OAS execution. *)
let resolve_providers_from_model_strings ?provider_filter
    ?(require_tool_choice_support = false)
    ?(require_tool_support = false)
    ?runtime_mcp_policy
    model_strings =
  Cascade_runtime.resolve_providers_from_model_strings ?provider_filter
    ?runtime_mcp_policy
    ~require_tool_choice_support ~require_tool_support model_strings

let keeper_agent_name_opt (keeper_name : string) =
  let keeper_name = String.trim keeper_name in
  if keeper_name = "" then None
  else Some (Keeper_types.keeper_agent_name keeper_name)

let runtime_mcp_policy_for_tools ~(keeper_name : string) (tools : Oas.Tool.t list)
    =
  let agent_name = keeper_agent_name_opt keeper_name in
  let runtime_tool_names =
    tools
    |> List.filter (fun (tool : Oas.Tool.t) ->
           Tool_catalog.is_public_mcp tool.schema.name
           ||
           (Option.is_some agent_name
            && Tool_catalog.is_on_surface Tool_catalog.Keeper_internal
                 tool.schema.name))
    |> List.map (fun (tool : Oas.Tool.t) -> tool.schema.name)
  in
  let has_keeper_internal =
    List.exists
      (Tool_catalog.is_on_surface Tool_catalog.Keeper_internal)
      runtime_tool_names
  in
  match
    Oas_worker_exec.runtime_mcp_policy_of_tool_names
      ?agent_name
      ~allow_keeper_internal:has_keeper_internal runtime_tool_names,
    agent_name
  with
  | Some policy, Some agent_name ->
      Some
        (Oas_worker_exec.runtime_mcp_policy_with_masc_agent_name
           ~agent_name policy)
  | Some policy, None -> Some policy
  | None, _ -> None

let runtime_mcp_policy_for_provider
    ~(keeper_name : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option) =
  let agent_name =
    keeper_agent_name_opt keeper_name |> Option.value ~default:""
  in
  Oas_worker_exec.runtime_mcp_policy_for_provider
    ~provider_cfg ~agent_name policy_opt

let codex_cli_cannot_carry_keeper_bound_runtime_mcp
    ~(keeper_name : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option) =
  match provider_cfg.kind, keeper_agent_name_opt keeper_name, policy_opt with
  | Llm_provider.Provider_config.Codex_cli, Some agent_name, Some policy
    when Option.is_some (Keeper_identity.keeper_name_from_agent_name agent_name)
    ->
      List.exists Oas_worker_exec.runtime_mcp_tool_requires_bound_actor
        policy.allowed_tool_names
  | _ -> false

let filter_candidate_providers_for_tool_support
    ~(keeper_name : string)
    ?runtime_mcp_policy
    ?(tools = [])
    ~require_tool_choice_support
    ~require_tool_support
    ~label
    (provider_cfgs : Llm_provider.Provider_config.t list) =
  if not require_tool_choice_support && not require_tool_support then
    provider_cfgs
  else
    let filtered =
      List.filter
        (fun provider_cfg ->
           let normalized_runtime_mcp_policy =
             runtime_mcp_policy_for_provider
               ~keeper_name ~provider_cfg runtime_mcp_policy
           in
           let tool_lane_supported =
             match tools with
             | [] -> true
             | _ -> (
                 match
                   Oas_worker_exec.resolve_tool_lane_for_oas_tools
                     ?agent_name:(keeper_agent_name_opt keeper_name)
                     ~tool_requirement:
                       (if require_tool_choice_support || require_tool_support
                        then `Required
                        else `Optional)
                     ~provider_cfg ~tools ()
                 with
                 | Ok _ -> true
                 | Error _ -> false)
           in
           (not
              (codex_cli_cannot_carry_keeper_bound_runtime_mcp
                 ~keeper_name ~provider_cfg normalized_runtime_mcp_policy))
           && tool_lane_supported
           && Provider_tool_support.supports_required_tool_use
             ?runtime_mcp_policy:normalized_runtime_mcp_policy
             ~require_tool_choice_support
             ~require_tool_support
             provider_cfg)
        provider_cfgs
    in
    if filtered = [] && provider_cfgs <> [] then
      Log.Misc.warn
        "cascade %s: provider-normalized tool-use gate removed all providers (providers=[%s])"
        label
        (String.concat ", "
           (List.map Provider_tool_support.provider_debug_label provider_cfgs));
    filtered

type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : string;
      reason : Keeper_types.cascade_exhaustion_reason;
    }
  | Resumable_cli_session of {
      cascade_name : string;
      detail : string;
      exit_code : int option;
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
  | Admission_queue_rejected of {
      keeper_name : string;
      reason : string;
    }
  | Turn_timeout of {
      elapsed_sec : float;
    }
  | Oas_timeout_budget of {
      budget_sec : float;
      keeper_turn_timeout_sec : float;
      estimated_input_tokens : int;
      source : string;
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
  | Resumable_cli_session { cascade_name; detail; exit_code } ->
    `Assoc
      [
        ("kind", `String "resumable_cli_session");
        ("cascade_name", `String cascade_name);
        ("detail", `String detail);
        ("exit_code", Json_util.int_opt_to_json exit_code);
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
  | Admission_queue_rejected { keeper_name; reason } ->
    `Assoc
      [
        ("kind", `String "admission_queue_rejected");
        ("keeper_name", `String keeper_name);
        ("reason", `String reason);
      ]
  | Turn_timeout { elapsed_sec } ->
    `Assoc
      [
        ("kind", `String "turn_timeout");
        ("elapsed_sec", `Float elapsed_sec);
      ]
  | Oas_timeout_budget
      {
        budget_sec;
        keeper_turn_timeout_sec;
        estimated_input_tokens;
        source;
      } ->
    `Assoc
      [
        ("kind", `String "oas_timeout_budget");
        ("budget_sec", `Float budget_sec);
        ("keeper_turn_timeout_sec", `Float keeper_turn_timeout_sec);
        ("estimated_input_tokens", `Int estimated_input_tokens);
        ("source", `String source);
      ]
  | Ambiguous_post_commit { is_timeout; tools; original_error } ->
    `Assoc
      [
        ("kind", `String "ambiguous_post_commit");
        ("is_timeout", `Bool is_timeout);
        ("tools", `List (List.map (fun v -> `String v) tools));
        ("original_error", `String original_error);
      ]

(* #9933: classify emitted [masc_oas_error] payloads by kind so
   dashboards and Grafana alerts can watch the fleet-wide rate per
   error class (cascade_exhausted vs oas_timeout_budget vs
   ambiguous_post_commit, etc.) rather than reading the free-form
   BDI blocker string.  125 [oas_timeout_budget] events accumulated
   across 9 keepers in 24h without an aggregate signal — this
   counter is the per-kind surface.

   Emit point is this constructor so all 14 call sites of
   [sdk_error_of_masc_internal_error] are covered automatically,
   without changing their signatures or threading [keeper_name]
   through callers that do not have it readily.  A follow-up PR
   can add a [keeper] label once every construction site has the
   name in scope. *)
let masc_oas_error_total_metric = "masc_oas_error_total"

let kind_of_masc_internal_error = function
  | Cascade_exhausted _ -> "cascade_exhausted"
  | Resumable_cli_session _ -> "resumable_cli_session"
  | No_tool_capable_provider _ -> "no_tool_capable_provider"
  | Accept_rejected _ -> "accept_rejected"
  | Admission_queue_timeout _ -> "admission_queue_timeout"
  | Admission_queue_rejected _ -> "admission_queue_rejected"
  | Turn_timeout _ -> "turn_timeout"
  | Oas_timeout_budget _ -> "oas_timeout_budget"
  | Ambiguous_post_commit _ -> "ambiguous_post_commit"

let sdk_error_of_masc_internal_error err =
  Prometheus.inc_counter masc_oas_error_total_metric
    ~labels:[ ("kind", kind_of_masc_internal_error err) ] ();
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
  let int_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Int value) -> Some value
        | Some (`Intlit value) -> int_of_string_opt value
        | _ -> None)
    | _ -> None
  in
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
           | Some (`String "resumable_cli_session") -> (
               match string_opt_of_assoc "cascade_name" json, string_opt_of_assoc "detail" json with
               | Some cascade_name, Some detail ->
                 Some
                   (Resumable_cli_session
                      {
                        cascade_name;
                        detail;
                        exit_code = int_opt_of_assoc "exit_code" json;
                      })
               | _ -> None)
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
           | Some (`String "admission_queue_rejected") -> (
               match string_opt_of_assoc "keeper_name" json,
                     string_opt_of_assoc "reason" json
               with
               | Some keeper_name, Some reason ->
                 Some (Admission_queue_rejected { keeper_name; reason })
               | _ -> None)
           | Some (`String "turn_timeout") -> (
               match json with
               | `Assoc fields -> (
                   match List.assoc_opt "elapsed_sec" fields with
                   | Some (`Float v) ->
                     Some (Turn_timeout { elapsed_sec = v })
                   | _ -> None)
               | _ -> None)
           | Some (`String "oas_timeout_budget") -> (
               match json with
               | `Assoc fields -> (
                   match
                     List.assoc_opt "budget_sec" fields,
                     List.assoc_opt "keeper_turn_timeout_sec" fields,
                     List.assoc_opt "estimated_input_tokens" fields,
                     List.assoc_opt "source" fields
                   with
                   | Some (`Float budget_sec),
                     Some (`Float keeper_turn_timeout_sec),
                     Some (`Int estimated_input_tokens),
                     Some (`String source) ->
                       Some
                         (Oas_timeout_budget
                            {
                              budget_sec;
                              keeper_turn_timeout_sec;
                              estimated_input_tokens;
                              source;
                            })
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
    ~(tools : Oas.Tool.t list)
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

let retry_message_looks_like_not_found (message : string) : bool =
  String_util.contains_substring_ci message "not found"
  || String_util.contains_substring_ci message "status code: 404"
  || String_util.contains_substring_ci message "404 page not found"

(** Convert an OAS sdk_error into a Cascade_fsm provider_outcome.
    API-level errors and model-capability-dependent agent errors are
    cascadeable (a different provider may succeed).  Structural agent
    errors (budget, idle, exit) are not — they would recur on any model. *)
let sdk_error_to_cascade_outcome (err : Oas.Error.sdk_error)
    : Cascade_fsm.provider_outcome option =
  match classify_masc_internal_error err with
  | Some (Resumable_cli_session { detail; _ }) ->
    Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.NetworkError
            { message = detail; kind = Llm_provider.Http_client.Unknown }))
  | _ -> (
  match err with
  | Oas.Error.Api api_err ->
    let http_err = match[@warning "-8"] api_err with
      | Llm_provider.Retry.InvalidRequest { message } ->
        let code =
          if retry_message_looks_like_not_found message then 404 else 400
        in
        Llm_provider.Http_client.HttpError { code; body = message }
      | Llm_provider.Retry.ContextOverflow { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 400; body = message }
      | Llm_provider.Retry.RateLimited { message; _ } ->
        Llm_provider.Http_client.HttpError { code = 429; body = message }
      | Llm_provider.Retry.NotFound { message } ->
        Llm_provider.Http_client.HttpError { code = 404; body = message }
      | Llm_provider.Retry.ServerError { status; message } ->
        Llm_provider.Http_client.HttpError { code = status; body = message }
      | Llm_provider.Retry.AuthError { message } ->
        Llm_provider.Http_client.HttpError { code = 401; body = message }
      | Llm_provider.Retry.Overloaded { message } ->
        Llm_provider.Http_client.HttpError { code = 529; body = message }
      | Llm_provider.Retry.NetworkError { message; kind } ->
        Llm_provider.Http_client.NetworkError { message; kind }
      | Llm_provider.Retry.Timeout { message } ->
        Llm_provider.Http_client.NetworkError
          { message; kind = Llm_provider.Http_client.Timeout }
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
  | Oas.Error.Config
      (Oas.Error.InvalidConfig { field = "runtime_mcp_auth"; detail })
  | Oas.Error.Config
      (Oas.Error.InvalidConfig { field = "tool_support"; detail }) ->
    Some
      (Cascade_fsm.Call_err
         (Llm_provider.Http_client.AcceptRejected { reason = detail }))
  | _ -> None)

let moonshot_auth_hint_marker = "Moonshot returned 401"
let openai_compat_not_found_hint_marker =
  "OpenAI-compatible endpoint returned 404"

let is_moonshot_provider (provider_cfg : Llm_provider.Provider_config.t) =
  String_util.contains_substring_ci provider_cfg.base_url "moonshot.ai"
  || String.starts_with ~prefix:"kimi" provider_cfg.model_id

let resolve_kimi_api_key_env_name ~cascade_name =
  let fallback_env = "KIMI_API_KEY_SB" in
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
      && retry_message_looks_like_not_found message ->
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
  "\"api_error_status\":429";
  "you've hit your limit";
  "monthly usage limit";
  "org's monthly usage limit";
  "resets apr ";
]

let message_looks_like_cli_wrapped_hard_quota (message : string) : bool =
  let contains needle =
    String_util.contains_substring_ci message needle
  in
  List.exists contains cli_wrapped_hard_quota_indicators
  ||
  (contains "claude exited with code 1"
   && contains "\"api_error_status\":429"
   && contains "you've hit your limit")

let cli_wrapped_max_turns_indicators = [
  "\"subtype\":\"error_max_turns\"";
  "error_max_turns";
  "\"terminal_reason\":\"max_turns\"";
  "terminal_reason\":\"max_turns";
  "reached maximum number of turns";
  "max turns exceeded";
]

let message_looks_like_cli_wrapped_max_turns (message : string) : bool =
  let contains needle =
    String_util.contains_substring_ci message needle
  in
  List.exists contains cli_wrapped_max_turns_indicators

let exit_code_of_message (message : string) : int option =
  let prefix = "exited with code " in
  match String.index_opt message ' ' with
  | None -> None
  | Some first_space ->
      let search_from = first_space + 1 in
      if search_from >= String.length message then None
      else
        let suffix =
          String.sub message search_from (String.length message - search_from)
        in
        if not (String.starts_with ~prefix suffix) then None
        else
          match String.index_from_opt suffix (String.length prefix) ':' with
          | None -> None
          | Some colon ->
              let raw =
                String.sub suffix (String.length prefix)
                  (colon - String.length prefix)
                |> String.trim
              in
              int_of_string_opt raw

let message_looks_like_resumable_cli_session (message : string) : bool =
  Oas_worker_exec.Kimi_cli_transport_local.text_looks_like_resumable_session
    message

let resumable_cli_session_detail (message : string) : string =
  Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail_of_text
    message

let resumable_cli_session_exit_code (message : string) : int option =
  Oas_worker_exec.Kimi_cli_transport_local.resumable_session_exit_code_of_text
    message

let sdk_error_to_resumable_cli_session ~cascade_name
    (err : Oas.Error.sdk_error) =
  match classify_masc_internal_error err with
  | Some (Resumable_cli_session _) -> Some err
  | _ ->
      let message = Oas.Error.to_string err in
      if message_looks_like_resumable_cli_session message then
        Some
          (sdk_error_of_masc_internal_error
             (Resumable_cli_session
                {
                  cascade_name;
                  detail = resumable_cli_session_detail message;
                  exit_code = resumable_cli_session_exit_code message;
                }))
      else None

let sdk_error_is_hard_quota (err : Oas.Error.sdk_error) : bool =
  match err with
  | Oas.Error.Api api_err ->
    Llm_provider.Retry.is_hard_quota api_err
    ||
    (match[@warning "-8"] api_err with
     | Llm_provider.Retry.NetworkError { message; _ }
     | Llm_provider.Retry.Overloaded { message }
     | Llm_provider.Retry.ServerError { message; _ } ->
       message_looks_like_cli_wrapped_hard_quota message
     | Llm_provider.Retry.RateLimited _
     | Llm_provider.Retry.AuthError _
     | Llm_provider.Retry.NotFound _
     | Llm_provider.Retry.InvalidRequest _
     | Llm_provider.Retry.ContextOverflow _
     | Llm_provider.Retry.Timeout _ ->
       false)
  | _ -> false

let sdk_error_is_max_turns_exceeded (err : Oas.Error.sdk_error) : bool =
  match classify_masc_internal_error err with
  | Some
      (Cascade_exhausted
         { reason = Keeper_types.Max_turns_exceeded; _ }) ->
      true
  | Some
      (Cascade_exhausted
         { reason = Keeper_types.Other_detail detail; _ }) ->
      message_looks_like_cli_wrapped_max_turns detail
  | Some (Cascade_exhausted _)
  | Some (Resumable_cli_session _)
  | Some (No_tool_capable_provider _)
  | Some (Accept_rejected _)
  | Some (Admission_queue_timeout _)
  | Some (Admission_queue_rejected _)
  | Some (Turn_timeout _)
  | Some (Oas_timeout_budget _)
  | Some (Ambiguous_post_commit _) ->
      false
  | None -> (
      match err with
      | Oas.Error.Agent (Oas.Error.MaxTurnsExceeded _) -> true
      | Oas.Error.Api
          (Llm_provider.Retry.NetworkError { message; _ }
          | Llm_provider.Retry.Overloaded { message }
          | Llm_provider.Retry.ServerError { message; _ }
          | Llm_provider.Retry.InvalidRequest { message }
          | Llm_provider.Retry.Timeout { message }) ->
          message_looks_like_cli_wrapped_max_turns message
      | Oas.Error.Api
          (Llm_provider.Retry.RateLimited _
          | Llm_provider.Retry.AuthError _
          | Llm_provider.Retry.NotFound _
          | Llm_provider.Retry.ContextOverflow _) ->
          false
      | Oas.Error.Internal message ->
          message_looks_like_cli_wrapped_max_turns message
      | _ -> false)

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
    ?stream_idle_timeout_s
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
    ?(required_tool_satisfaction =
      Oas.Completion_contract.any_tool_call_satisfies)
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
    ?per_provider_timeout_s
    ()
  : (Oas_worker_exec.run_result, Oas.Error.sdk_error) result =
  match require_eio ?sw ?net () with
  | Error e -> Error (eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
  let cascade_name =
    let trimmed = String.trim cascade_name in
    if Option.is_some model_strings && trimmed <> "" then trimmed
    else Keeper_cascade_profile.normalize_declared_name cascade_name
  in
  let runtime_mcp_policy = runtime_mcp_policy_for_tools ~keeper_name tools in
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
  let candidate_cfgs =
    filter_candidate_providers_for_tool_support
      ~keeper_name
      ?runtime_mcp_policy
      ~tools
      ~require_tool_choice_support
      ~require_tool_support
      ~label:cascade_name
      candidate_cfgs
  in
  let capture, _metrics = Oas_worker_cascade.cascade_metrics_for_candidates ~candidate_cfgs () in
  let cascade_strategy_name_ref = ref None in
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
  let try_provider ?resume_checkpoint ?per_provider_timeout_s (provider_cfg : Llm_provider.Provider_config.t) =
    let config_result =
      Oas_worker_exec.resolve_tool_lane_for_oas_tools
        ?agent_name:(keeper_agent_name_opt keeper_name)
        ~tool_requirement:
          (if require_tool_choice_support || require_tool_support
           then `Required
           else `Optional)
        ~provider_cfg ~tools ()
      |> Result.map
           (fun (effective_tools, runtime_mcp_policy) ->
             let runtime_mcp_policy =
               match runtime_mcp_policy, String.trim keeper_name with
               | Some policy, keeper_name when keeper_name <> "" ->
                   Oas_worker_exec.runtime_mcp_policy_for_provider
                     ~provider_cfg
                     ~agent_name:(Keeper_types.keeper_agent_name keeper_name)
                     (Some policy)
                | _ -> runtime_mcp_policy
             in
             {
               (Oas_worker_exec.default_config ~name ~provider_cfg
                  ~system_prompt ~tools:effective_tools)
               with
                 priority;
                 max_turns;
                 max_tokens;
                 max_input_tokens;
                 max_cost_usd;
                 stream_idle_timeout_s =
                   (match per_provider_timeout_s with
                    | Some _ as timeout_s -> timeout_s
                    | None -> stream_idle_timeout_s);
                 temperature;
                 max_idle_turns;
                 guardrails;
                 hooks;
                 context_reducer;
                 memory;
                 tool_retry_policy;
                 required_tool_satisfaction;
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
            let run_fn () =
              Oas_worker_exec.run ~sw ~net ~config
                ?oas_checkpoint:effective_checkpoint ?on_event
                ?on_yield ?on_resume ~agent_ref:local_agent_ref ?proof_ref
                ?contract goal
            in
            let result =
              match per_provider_timeout_s with
              | None -> run_fn ()
              | Some t ->
                  let clock_opt =
                    match Masc_eio_env.get_opt () with
                    | Some env -> (
                        match env.clock with
                        | Some _ as clock_opt -> clock_opt
                        | None -> Eio_context.get_clock_opt ())
                    | None -> Eio_context.get_clock_opt ()
                  in
                  (match clock_opt with
                   | Some clock ->
                       (try Eio.Time.with_timeout_exn clock t run_fn
                        with Eio.Time.Timeout ->
                          Log.Misc.info
                            "[cascade-fallback] cascade %s: provider %s per-provider timeout after %.1fs, falling back"
                            cascade_name provider_cfg.model_id t;
                          Error (Oas.Error.Api (Timeout { message = Printf.sprintf "Per-provider timeout after %.1fs" t })))
                   | None -> run_fn ())
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
      ?resume_checkpoint ?per_provider_timeout_s remaining last_err =
    match remaining with
    | [] ->
      let reason : Keeper_types.cascade_exhaustion_reason = match last_err with
        | Some (Llm_provider.Http_client.NetworkError { message; kind }) ->
            if kind = Llm_provider.Http_client.Connection_refused
               || String_util.contains_substring_ci message "connection refused" then
              Keeper_types.Connection_refused
            else if message_looks_like_cli_wrapped_max_turns message then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail message
        | Some (Llm_provider.Http_client.HttpError { code; body }) ->
            if message_looks_like_cli_wrapped_max_turns body then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail
                (Printf.sprintf "HTTP %d: %s" code
                  (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." body |> String_util.to_string))
        | Some (Llm_provider.Http_client.AcceptRejected { reason = r }) ->
            if message_looks_like_cli_wrapped_max_turns r then
              Keeper_types.Max_turns_exceeded
            else
              Keeper_types.Other_detail r
        | Some (Llm_provider.Http_client.CliTransportRequired { kind }) ->
            Keeper_types.Other_detail
              (Printf.sprintf "%s provider requires a CLI transport" kind)
        | None -> Keeper_types.No_providers_available
      in
      let observation =
        Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
          ?strategy:!cascade_strategy_name_ref ~configured_labels
          ~candidate_cfgs ~selected_model_raw:None ~capture ()
      in
      Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
      let terminal_error =
        match last_err with
        | Some (Llm_provider.Http_client.NetworkError { message; _ })
          when message_looks_like_resumable_cli_session message ->
            sdk_error_of_masc_internal_error
              (Resumable_cli_session
                 {
                   cascade_name;
                   detail = resumable_cli_session_detail message;
                   exit_code = resumable_cli_session_exit_code message;
                 })
        | Some (Llm_provider.Http_client.AcceptRejected { reason })
          when message_looks_like_resumable_cli_session reason ->
            sdk_error_of_masc_internal_error
              (Resumable_cli_session
                 {
                   cascade_name;
                   detail = resumable_cli_session_detail reason;
                   exit_code = resumable_cli_session_exit_code reason;
                 })
        | _ ->
            sdk_error_of_masc_internal_error
              (Cascade_exhausted
                 {
                   cascade_name;
                   reason;
                 })
      in
      Error
        terminal_error
    | (provider_cfg : Llm_provider.Provider_config.t) :: rest ->
      let is_last = rest = [] in
      Log.Misc.debug "cascade %s: trying %s (is_last=%b)" cascade_name provider_cfg.model_id is_last;
      let pp_timeout = if is_last then None else per_provider_timeout_s in
      let (result, checkpoint_after) = try_provider ?resume_checkpoint ?per_provider_timeout_s:pp_timeout provider_cfg in
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
          Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
            ?strategy:!cascade_strategy_name_ref ~configured_labels
            ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
            ~capture ()
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
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some response.model)
               ~capture ()
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
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some result.response.model)
               ~capture ()
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
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_cfgs ~selected_model_raw:(Some resp.model) ~capture ()
           in
           let result = { result with cascade_observation = Some observation } in
           Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Success ~observation:(Some observation);
           on_success ~provider_key:provider_cfg.model_id;
           Ok result)
      | Error sdk_err ->
        let sdk_err =
          match sdk_error_to_resumable_cli_session ~cascade_name sdk_err with
          | Some err -> err
          | None -> sdk_err
        in
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
                Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
                  ?strategy:!cascade_strategy_name_ref ~configured_labels
                  ~candidate_cfgs ~selected_model_raw:None ~capture ()
              in
              Oas_worker_cascade.record_cascade ~cascade_name ~outcome:`Failure ~observation:(Some observation);
              Log.Misc.error "cascade %s exhausted: all tiers failed (last model=%s, error=%s)"
                cascade_name provider_cfg.model_id (Oas.Error.to_string sdk_err);
              Error sdk_err
            | _ -> Error sdk_err)
         | None ->
           (* Non-API error (agent, config, etc.) — not cascadeable *)
           let observation =
             Oas_worker_cascade.cascade_observation_with_metrics ~cascade_name
               ?strategy:!cascade_strategy_name_ref ~configured_labels
               ~candidate_cfgs ~selected_model_raw:None ~capture ()
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
  let strategy_name = Cascade_strategy.kind_to_string strategy.kind in
  let () = cascade_strategy_name_ref := Some strategy_name in
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
        ?strategy:!cascade_strategy_name_ref ~configured_labels
        ~candidate_cfgs ~selected_model_raw:None ~capture ()
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
      strategy = strategy_name;
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
        cascade_name n strategy_name;
      do_backoff (n + 1);
      cycle_loop (n + 1)
    | _ ->
      record_trace ~cycle:n ~candidates_out:(List.length ordered)
        ~backoff_ms:0 ~kind:Ordered;
      let on_success ~provider_key =
        Cascade_strategy.record_choice strategy ~ctx:signal_ctx ~provider_key
      in
      (match try_cascade ~on_success ?per_provider_timeout_s ordered None with
       | Ok _ as ok -> ok
       | Error _ as err when last_cycle -> err
       | Error _ ->
         Log.Misc.info
           "cascade %s: cycle %d exhausted, backoff before retry (strategy=%s)"
           cascade_name n strategy_name;
         do_backoff (n + 1);
         cycle_loop (n + 1))
  in
  match Admission_queue.with_permit ?wait_timeout_sec
    ~priority:queue_priority ~keeper_name:name ~cascade_name
    (fun () -> cycle_loop 0) with
  | Ok result -> result
  | Error (`Host_resource_saturated reason) ->
      Error
        (sdk_error_of_masc_internal_error
           (Admission_queue_rejected { keeper_name = name; reason })))

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Validates the label parses before attempting execution. *)
let run_model_by_label
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?(max_turns = 20)
    ?(max_idle_turns = 3)
    ?stream_idle_timeout_s
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
      ~max_idle_turns ?stream_idle_timeout_s ?guardrails ?hooks ?context_reducer ?memory
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
      match
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
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?stream_idle_timeout_s
    ?(temperature = Oas_worker_cascade.default_temperature)
    ?(max_tokens = Oas_worker_cascade.default_max_tokens)
    ?max_input_tokens
    ?max_cost_usd
    ?wait_timeout_sec
    ?guardrails
    ?hooks
    ?memory
    ?tool_retry_policy
    ?(required_tool_satisfaction =
      Oas.Completion_contract.any_tool_call_satisfies)
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
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ?(max_turns = 20)
    ?stream_idle_timeout_s
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
      ?stream_idle_timeout_s ?guardrails ?hooks ?memory ?tool_retry_policy ?enable_thinking
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
      match
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
      | Ok result -> result
      | Error (`Host_resource_saturated reason) ->
          Error
            (sdk_error_of_masc_internal_error
               (Admission_queue_rejected { keeper_name = "oas-explicit-model"; reason }))
