(** Runtime_transport — Transport and tool-lane helpers for OAS worker exec.

    Keeps provider label resolution, runtime MCP lane selection, and per-call
    CLI transport construction separate from the build/run orchestration in
    {!Runtime_agent}. *)

(* RFC-0167: the client-named omission-dedup helpers
   ([codex_cli_omission_fingerprint], [codex_cli_omission_fingerprint_seen],
   [record_codex_cli_omission], [record_codex_cli_omission_for_agent],
   [reset_codex_cli_omission_dedup_for_tests]) were removed in the
   big-bang sweep. Structural omission detection remains in the
   resolver below. *)

(** Failure modes for {!resolve_provider_config_of_label}. *)
type label_resolution_error =
  | Invalid_model_label of string

(** Render a label-resolution error for log/diagnostic surfaces. *)
val label_resolution_error_to_string : label_resolution_error -> string

(** Lift a label-resolution error into the OAS SDK error envelope. *)
val label_resolution_error_to_sdk_error :
  label_resolution_error -> Agent_sdk.Error.sdk_error

(** Resolve a model label string to a provider config via the MASC runtime
    parser.  Explicit labels never silently fall through to discovery-only
    models — unresolved labels return [Error (Invalid_model_label _)]. *)
val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t, label_resolution_error) result

(** Construct an [Agent_sdk.Error.InvalidConfig] with the supplied [field] name and
    [detail] text. *)
val invalid_runtime_config : string -> string -> Agent_sdk.Error.sdk_error

(** OAS capability snapshot for a provider config.  Alias for
    {!Provider_tool_support.oas_capabilities_of_config}. *)
val provider_caps_of_config :
  Llm_provider.Provider_config.t -> Llm_provider.Capabilities.capabilities

(** Whether a provider can accept inline tool definitions on a request.
    Alias for {!Provider_tool_support.provider_supports_inline_tools}. *)
val provider_supports_inline_tools :
  ?override:Provider_tool_support.runtime_capabilities_override ->
  Llm_provider.Provider_config.t -> bool

(** Whether a provider supports the runtime MCP tool lane.  Alias for
    {!Provider_tool_support.provider_supports_runtime_mcp_lane}. *)
val provider_supports_runtime_mcp_lane :
  ?override:Provider_tool_support.runtime_capabilities_override ->
  Llm_provider.Provider_config.t -> bool

(** Drop duplicates from a list while preserving the first-seen order. *)
val dedupe_preserve_order : string list -> string list

(** Extract the [name] field of every OAS tool. *)
val public_mcp_tool_names_of_oas_tools : Agent_sdk.Tool.t list -> string list

(** Filter [tools] to those whose name is a public MCP tool per
    {!Tool_catalog.is_public_mcp}. *)
val public_mcp_tools_of_oas_tools : Agent_sdk.Tool.t list -> Agent_sdk.Tool.t list

(** Whether every name in [tool_names] is a public MCP tool.  Empty input
    returns [false]. *)
val tool_names_are_public_mcp : string list -> bool

(** Whether a runtime MCP tool requires a request-scoped actor binding (alias
    for {!Tool_catalog.requires_actor_binding}). *)
val runtime_mcp_tool_requires_bound_actor : string -> bool

(** Whether a public MCP tool requires a request-scoped actor binding. *)
val public_mcp_tool_requires_bound_actor : string -> bool

(** Inject identity headers ([x-masc-agent-name], [x-masc-keeper-name]) into
    the [masc] HTTP server entry of [policy] when [agent_name] is non-empty.
    Authentication is never synthesized here; the policy builder must already
    carry the exact actor credential. Other servers are passed through. *)
val runtime_mcp_policy_with_masc_agent_name :
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy

val codex_cli_can_auth_keeper_bound_runtime_mcp :
  base_path:string ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  (bool, Auth_resolve.auth_error) result
(** [Ok true] when [agent_name] has an exact, current credential and [policy]
    contains actor-bound runtime MCP tools. Credential failures remain typed
    and are traced without exposing the bearer. *)

(** Provider-specific shaping of the runtime MCP policy.  For Cli_tool_a the
    policy is stripped to client-safe headers: [Authorization: Bearer ...]
    plus non-secret MASC identity headers.  Other providers receive the policy
    with [runtime_mcp_policy_with_masc_agent_name] applied when [agent_name] is
    non-empty. *)
val runtime_mcp_policy_for_provider :
  base_path:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  Llm_provider.Llm_transport.runtime_mcp_policy option

(** Build the runtime MCP policy that exposes [tool_names] back to the
    provider's CLI.  Returns [None] when the tool set is not eligible for
    the runtime MCP lane (e.g. mixed surface, missing keeper identity for
    agent-internal tools, or empty input). *)
val runtime_mcp_policy_of_tool_names :
  base_path:string ->
  ?agent_name:string ->
  ?allow_agent_internal:bool ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option

(** Public-only variant of {!runtime_mcp_policy_of_tool_names}.  Forwards
    without [allow_agent_internal]. *)
val public_mcp_runtime_policy_of_tool_names :
  base_path:string ->
  ?agent_name:string ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option

(** Human-readable [provider_kind:model_id] label. *)
val provider_label : Llm_provider.Provider_config.t -> string

(** Decide whether [tools] are served via runtime MCP lane, inline, or
    rejected as unsupported.  Returns [(remaining_inline_tools, policy)]:
    - [(_, Some policy)] — runtime MCP lane carries the tools (inline list
      is empty in that case).
    - [(tools, None)] — fall back to inline tools (when supported by the
      provider).
    - [Error sdk_error] — provider supports neither lane.

    Keeper-bound actor tools use the per-keeper raw bearer token when it is
    available, routed through OAS [bearer_token_env_var]. When no per-keeper
    token exists, the resolver excludes those tools from the resulting policy
    and keeps the turn alive with the remaining supported lane. *)
val resolve_tool_lane_for_oas_tools :
  base_path:string ->
  ?agent_name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  tools:Agent_sdk.Tool.t list ->
  unit ->
  ( Agent_sdk.Tool.t list
    * Llm_provider.Llm_transport.runtime_mcp_policy option,
    Agent_sdk.Error.sdk_error )
  result

(* CLI subprocess transport surface ([make_per_call_switch_transport],
   [non_http_transport_of_provider], [Json_stream_cli_transport_local]) was
   removed in the CLI provider purge (2026-05-31). Provider dispatch is
   HTTP-only. *)
