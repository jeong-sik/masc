(** Runtime_transport — Transport and tool-lane helpers for AGENT_CORE worker exec.

    Keeps provider label resolution and per-call CLI transport construction
    separate from the build/run orchestration in {!Runtime_agent}. *)

(** Failure modes for {!resolve_provider_config_of_label}. *)
type label_resolution_error =
  | Invalid_model_label of string

(** Render a label-resolution error for log/diagnostic surfaces. *)
val label_resolution_error_to_string : label_resolution_error -> string

(** Lift a label-resolution error into the AGENT_CORE agent-core error envelope. *)
val label_resolution_error_to_core_error :
  label_resolution_error -> Agent_core.Error.t

(** Resolve a model label string to a provider config via the MASC runtime
    parser.  Explicit labels never silently fall through to discovery-only
    models — unresolved labels return [Error (Invalid_model_label _)]. *)
val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t, label_resolution_error) result

(** Construct an [Agent_core.Error.InvalidConfig] with the supplied [field] name and
    [detail] text. *)
val invalid_runtime_config : string -> string -> Agent_core.Error.t

(** AGENT_CORE capability snapshot for a provider config.  Alias for
    {!Provider_tool_support.agent_core_capabilities_of_config}. *)
val provider_caps_of_config :
  Llm_provider.Provider_config.t -> Llm_provider.Capabilities.capabilities

(** Whether a provider can accept inline tool definitions on a request.
    Alias for {!Provider_tool_support.provider_supports_inline_tools}. *)
val provider_supports_inline_tools :
  ?override:Provider_tool_support.runtime_capabilities_override ->
  Llm_provider.Provider_config.t -> bool

(** Human-readable [provider_kind:model_id] label. *)
val provider_label : Llm_provider.Provider_config.t -> string

(* CLI subprocess transport surface ([make_per_call_switch_transport],
   [non_http_transport_of_provider], [Json_stream_cli_transport_local]) was
   removed in the CLI provider purge (2026-05-31). Provider dispatch is
   HTTP-only. *)
