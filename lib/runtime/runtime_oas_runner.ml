(** Runtime_oas_runner — Eio context, runtime resolution, runtime MCP policy.

    Extracted from oas_worker_named.ml (God file decomposition).
    Provides runtime profile defaults, Eio context validation,
    provider resolution, and tool-support filtering.

    @since God file decomposition *)

(* Runtime profile defaults (moved from Runtime module) *)

let default_config_path = Runtime.config_path

let default_model_strings ~runtime_id =
  Provider_runtime_projection.default_execution_model_strings runtime_id

(* Named model execution *)

let require_eio ?sw ?net () =
  let sw =
    match sw with
    | Some s -> Some s
    | None -> Eio_context.get_switch_opt ()
  in
  let net =
    match net with
    | Some n -> Some n
    | None -> Eio_context.get_net_opt ()
  in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

(* SSOT for the [InvalidConfig.field] tag that marks the MASC-internal
   "Eio context unavailable" error. Both the producer
   ([eio_context_error_to_sdk_error]) and the structural classifier
   ([is_eio_context_error]) reference this single binding, so the two sides
   cannot drift apart. *)
let eio_context_field = "eio_context"

let eio_context_error_to_sdk_error detail =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig { field = eio_context_field; detail })

(* [true] iff [err] is the "Eio switch/net unavailable" config error this
   module produces (running outside a server context). Matched structurally
   on the typed [Config (InvalidConfig { field })] tag — NOT by substring-
   scanning [Agent_sdk.Error.to_string]: the rendered Eio wording is not a
   contract and a wording change must not silently drop the fatal-environment
   promotion in the heartbeat loop. The producer and this predicate live in
   one module so the [field] tag is the single source of truth. The [when]
   guard keeps the [Config _] arm reachable regardless of how many
   constructors the wrapped config-error type carries. *)
let is_eio_context_error (err : Agent_sdk.Error.sdk_error) : bool =
  match err with
  | Agent_sdk.Error.Config (Agent_sdk.Error.InvalidConfig { field; _ })
    when String.equal field eio_context_field -> true
  | Agent_sdk.Error.Config _ -> false
  | Agent_sdk.Error.Provider _ -> false
  | Agent_sdk.Error.Api _ -> false
  | Agent_sdk.Error.Agent _ -> false
  | Agent_sdk.Error.Mcp _ -> false
  | Agent_sdk.Error.Serialization _ -> false
  | Agent_sdk.Error.Io _ -> false
  | Agent_sdk.Error.Orchestration _ -> false
  | Agent_sdk.Error.Internal _ -> false

let runtime_catalog_error_to_sdk_error detail =
  Agent_sdk.Error.Config
    (Agent_sdk.Error.InvalidConfig { field = "runtime_id"; detail })

(** Resolve runtime provider configs via MASC Runtime_config.
    Returns Provider_config.t list for the downstream OAS runtime,
    bypassing the old Model_spec facade. *)
let resolve_runtime_providers ~runtime_id () =
  (* Audit F8: honor the *requested* runtime id (RFC-0207 catalog lookup).
     The previous RFC-0206 single-binding stub discarded [runtime_id] and
     always returned the default runtime, silently substituting an
     operator-overridable id (e.g. MASC_KEEPER_LLM_RERANK_RUNTIME) — an
     Unknown→Permissive fallback. An empty id means the default runtime; a
     non-empty id that is not a configured runtime is an [Error] (no silent
     substitution — RFC-0206 §2.1). The former [?provider_filter] /
     [?runtime_mcp_policy] parameters were ignored here and are deleted;
     each resolved runtime carries exactly one provider_config. *)
  let runtime_id = String.trim runtime_id in
  if String.equal runtime_id "" then
    match Runtime.get_default_runtime () with
    | None -> Error "no default runtime configured"
    | Some rt -> Ok [ rt.Runtime.provider_config ]
  else
    match Runtime.get_runtime_by_id runtime_id with
    | Some rt -> Ok [ rt.Runtime.provider_config ]
    | None ->
      Error
        (Printf.sprintf
           "requested runtime %S not found among configured runtimes \
            (no silent fallback to default — RFC-0206 §2.1)"
           runtime_id)

(* Injected keeper name translators (dependency inversion of the
   runtime -> keeper-domain Keeper_identity edge). The runtime no longer
   code-depends on Keeper_identity; the keeper composition root registers the
   two pure name translators once at init via [set_keeper_name_xlat]. The
   accessor is fail-fast: an unset read raises rather than substituting an
   identity/None default, because a silent name mistranslation would be an
   unknown -> permissive-default error (and a module-level eager read could
   crash before init). *)
type keeper_name_xlat =
  { keeper_agent_name : string -> string
  ; keeper_name_from_agent_name : string -> string option
  }

let keeper_name_xlat : keeper_name_xlat option Atomic.t = Atomic.make None

let set_keeper_name_xlat (x : keeper_name_xlat) = Atomic.set keeper_name_xlat (Some x)

let require_keeper_name_xlat () =
  match Atomic.get keeper_name_xlat with
  | Some x -> x
  | None ->
    failwith
      "runtime_oas_runner: keeper_name_xlat not registered (keeper must call \
       Runtime_oas_runner.set_keeper_name_xlat at init)"

let keeper_agent_name_opt (keeper_name : string) =
  let keeper_name = String.trim keeper_name in
  if keeper_name = ""
  then None
  else Some ((require_keeper_name_xlat ()).keeper_agent_name keeper_name)

let runtime_mcp_policy_for_tools
      ~base_path
      ~(keeper_name : string)
      (tools : Agent_sdk.Tool.t list)
  =
  let agent_name = keeper_agent_name_opt keeper_name in
  (* The Agent_internal surface was empty, so the runtime tool set is exactly
     the public MCP tools and [allow_agent_internal] is always [false].
     Surface deleted in the surface-cut refactor. *)
  let runtime_tool_names =
    tools
    |> List.filter (fun (tool : Agent_sdk.Tool.t) ->
      Tool_catalog.is_public_mcp tool.schema.name)
    |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
  in
  match
	    ( Runtime_agent.runtime_mcp_policy_of_tool_names
	        ~base_path
	        ?agent_name
	        ~allow_agent_internal:false
	        runtime_tool_names
    , agent_name )
  with
  | Some policy, Some agent_name ->
    Some (Runtime_agent.runtime_mcp_policy_with_masc_agent_name ~agent_name policy)
  | Some policy, None -> Some policy
  | None, _ -> None

let runtime_mcp_policy_for_provider
      ~base_path
      ~(keeper_name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  let agent_name = keeper_agent_name_opt keeper_name |> Option.value ~default:"" in
  Runtime_agent.runtime_mcp_policy_for_provider ~base_path ~provider_cfg ~agent_name policy_opt

let codex_cli_cannot_carry_keeper_bound_runtime_mcp
      ~base_path
      ~(keeper_name : string)
      ~(provider_cfg : Llm_provider.Provider_config.t)
      (policy_opt : Llm_provider.Llm_transport.runtime_mcp_policy option)
  =
  (* RFC-0058 §2.4: dispatch by local tool-delivery policy, not provider name. *)
  if
    not
      (Provider_tool_support
       .provider_requires_per_keeper_bridging_for_bound_actor_tools
         provider_cfg)
  then false
  else (
    match keeper_agent_name_opt keeper_name, policy_opt with
    | Some agent_name, Some policy
      when Option.is_some
	             ((require_keeper_name_xlat ()).keeper_name_from_agent_name agent_name) ->
      let has_bound_actor_tools =
        List.exists Runtime_agent.runtime_mcp_tool_requires_bound_actor
          policy.allowed_tool_names
      in
      (match
         Runtime_agent.codex_cli_can_auth_keeper_bound_runtime_mcp ~base_path
           ~agent_name policy
       with
      | Ok can_auth -> (not can_auth) && has_bound_actor_tools
      | Error _ -> has_bound_actor_tools)
    | _ -> false)
