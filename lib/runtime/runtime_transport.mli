(** Runtime_transport — Transport and tool-lane helpers for OAS worker exec.

    Keeps provider label resolution, runtime MCP lane selection, and per-call
    CLI transport construction separate from the build/run orchestration in
    {!Runtime_agent}. *)

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

(** Build the runtime MCP policy that exposes the caller-supplied, non-empty
    [tool_names] back to the provider's runtime MCP lane. The caller schemas are
    the transport identity SSOT; no static product catalog reclassifies them.
    Returns [None] for invalid names or when required workspace authentication
    cannot be resolved. *)
val runtime_mcp_policy_of_tool_names :
  base_path:string ->
  ?agent_name:string ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option

(** Human-readable [provider_kind:model_id] label. *)
val provider_label : Llm_provider.Provider_config.t -> string

(** Preserve the exact inline Keeper tool values. Provider capability and
    credential state are execution concerns and never remove a model-visible
    schema before invocation. The policy component is therefore always
    [None]. *)
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
