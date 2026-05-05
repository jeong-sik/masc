(** Oas_worker_exec_transport — Transport and tool-lane helpers for OAS worker exec.

    Keeps provider label resolution, runtime MCP lane selection, and per-call
    CLI transport construction separate from the build/run orchestration in
    {!Oas_worker_exec}. *)

(** Per-call overrides forwarded to CLI transports.  Each field is consulted
    only by the matching provider kind; missing fields fall back to the
    transport's [default_config]. *)
type cli_transport_overrides = {
  cwd : string option;
  claude_mcp_config : string option;
  claude_allowed_tools : string list option;
  claude_permission_mode : string option;
  claude_max_turns : int option;
  gemini_yolo : bool option;
}

(** Hard cap for Claude Code's internal agent loop.  MASC may run a keeper
    for more turns overall, but a single Claude Code subprocess attempt must
    not receive that keeper-level budget unchanged. *)
val claude_code_max_turns_hard_cap : int

(** Clamp provider-internal max_turns to provider hard constraints. *)
val provider_effective_max_turns :
  Llm_provider.Provider_config.provider_kind -> int -> int

(** Sorted, comma-joined fingerprint of a tool list.  Used as the dedup key
    by the [#10097] omission machinery — identical sets fingerprint to the
    same string regardless of input order. *)
val codex_cli_omission_fingerprint : string list -> string

(** Whether a fingerprint has already been observed by the omission machinery
    for the [<no_agent>] bucket.  Returns [false] only when the fingerprint
    is new (and updates dedup state as a side effect, equivalent to a
    [should_log] probe with the [<no_agent>] key). *)
val codex_cli_omission_fingerprint_seen : string -> bool

(** Record a [#10097] codex_cli MCP-tool omission for an unspecified agent.
    Increments per-tool Prometheus counters every call; the structural WARN
    log fires only when a new tool fingerprint is seen.  See
    {!record_codex_cli_omission_for_agent} for the per-agent variant used by
    the cascade pipeline. *)
val record_codex_cli_omission : tools:string list -> unit

(** Reset the codex_cli omission dedup state.  Test-only helper exposed for
    [test_codex_cli_omission_dedup_10097]. *)
val reset_codex_cli_omission_dedup_for_tests : unit -> unit

(** Failure modes for {!resolve_provider_config_of_label}. *)
type label_resolution_error =
  | Invalid_model_label of string

(** Render a label-resolution error for log/diagnostic surfaces. *)
val label_resolution_error_to_string : label_resolution_error -> string

(** Lift a label-resolution error into the OAS SDK error envelope. *)
val label_resolution_error_to_sdk_error :
  label_resolution_error -> Agent_sdk.Error.sdk_error

(** Resolve a model label string to a provider config via the MASC cascade
    parser.  Explicit labels never silently fall through to discovery-only
    models — unresolved labels return [Error (Invalid_model_label _)]. *)
val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t, label_resolution_error) result

(** Construct an [Agent_sdk.Error.InvalidConfig] with the supplied [field] name and
    [detail] text. *)
val invalid_runtime_config : string -> string -> Agent_sdk.Error.sdk_error

(** Normalize a CLI [model_id] to an explicit override.  Returns [None] when
    the model id is empty or [auto] (case-insensitive after trim). *)
val cli_model_override : string -> string option

(** OAS capability snapshot for a provider config.  Alias for
    {!Provider_tool_support.oas_capabilities_of_config}. *)
val provider_caps_of_config :
  Llm_provider.Provider_config.t -> Llm_provider.Capabilities.capabilities

(** Whether a provider can accept inline tool definitions on a request.
    Alias for {!Provider_tool_support.provider_supports_inline_tools}. *)
val provider_supports_inline_tools : Llm_provider.Provider_config.t -> bool

(** Whether a provider supports the runtime MCP tool lane.  Alias for
    {!Provider_tool_support.provider_supports_runtime_mcp_lane}. *)
val provider_supports_runtime_mcp_lane :
  Llm_provider.Provider_config.t -> bool

(** Render the [mcpServers] config JSON consumed by [kimi_cli], filtering
    by [policy.allowed_server_names].  Returns [None] when no allowed
    server remains after filtering. *)
val kimi_mcp_config_json_of_policy :
  Llm_provider.Llm_transport.runtime_mcp_policy -> string option

(** Resolve the kimi_cli model name for a provider, falling back to
    [Transport_kimi_cli.default_config.model] when the provider's
    [model_id] is [auto] or empty. *)
val kimi_cli_model_for_provider :
  Llm_provider.Provider_config.t -> string option

(** Render the kimi_cli root config JSON (default_model + providers + models)
    for a provider.  Returns [None] when either the model resolution or the
    auth value resolution fails. *)
val kimi_cli_config_json_for_provider :
  Llm_provider.Provider_config.t -> string option

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
    [x-masc-internal-token] is also injected by default when
    [MASC_INTERNAL_MCP_TOKEN] is available; pass
    [~include_internal_token:false] for providers such as [codex_cli] that
    cannot carry auth-bearing request headers.  Other servers are passed
    through. *)
val runtime_mcp_policy_with_masc_agent_name :
  ?include_internal_token:bool ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy

val codex_cli_can_auth_keeper_bound_runtime_mcp :
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  bool
(** [true] when [agent_name] maps to a keeper with a persisted raw bearer
    token and [policy] contains actor-bound runtime MCP tools.  Codex CLI
    can carry that token via OAS [bearer_token_env_var] without placing it in
    argv. *)

(** Provider-specific shaping of the runtime MCP policy.  For Codex_cli the
    policy is stripped to Codex-safe headers: [Authorization: Bearer ...]
    plus non-secret MASC identity headers.  Other providers receive the policy
    with [runtime_mcp_policy_with_masc_agent_name] applied when [agent_name] is
    non-empty. *)
val runtime_mcp_policy_for_provider :
  provider_cfg:Llm_provider.Provider_config.t ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  Llm_provider.Llm_transport.runtime_mcp_policy option

(** Compose the kimi_cli [--mcp-config] arguments from a [base] list and an
    optional runtime MCP policy.  Output is deduped, preserving order. *)
val kimi_cli_runtime_mcp_jsons :
  base:string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string list

(** Build the runtime MCP policy that exposes [tool_names] back to the
    provider's CLI.  Returns [None] when the tool set is not eligible for
    the runtime MCP lane (e.g. mixed surface, missing keeper identity for
    keeper-internal tools, or empty input). *)
val runtime_mcp_policy_of_tool_names :
  ?agent_name:string ->
  ?allow_keeper_internal:bool ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option

(** Public-only variant of {!runtime_mcp_policy_of_tool_names}.  Forwards
    without [allow_keeper_internal]. *)
val public_mcp_runtime_policy_of_tool_names :
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

    Codex_cli + keeper-bound actor tools trigger the [#10097] omission
    counter/log path; the resulting policy excludes those tools. *)
val resolve_tool_lane_for_oas_tools :
  ?agent_name:string ->
  ?tool_requirement:[ `Required | `Optional ] ->
  provider_cfg:Llm_provider.Provider_config.t ->
  tools:Agent_sdk.Tool.t list ->
  unit ->
  ( Agent_sdk.Tool.t list
    * Llm_provider.Llm_transport.runtime_mcp_policy option,
    Agent_sdk.Error.sdk_error )
  result

(** Wrap a CLI transport factory in a per-call sub-switch so that any
    pipe/process resources allocated by the factory are deterministically
    released at the end of each completion call. *)
val make_per_call_switch_transport :
  (sw:Eio.Switch.t -> Llm_provider.Llm_transport.t) ->
  Llm_provider.Llm_transport.t

(** Construct a non-HTTP CLI transport for [provider_cfg] (Claude_code,
    Gemini_cli, Kimi_cli, Codex_cli).  Returns [Ok None] for HTTP-only
    providers (Anthropic, OpenAI_compat, Ollama, Gemini, Glm, Kimi,
    DashScope).  Returns [Error] when the process manager is not initialized. *)
val non_http_transport_of_provider :
  sw:Eio.Switch.t ->
  provider_cfg:Llm_provider.Provider_config.t ->
  ?runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy ->
  ?cli_transport_overrides:cli_transport_overrides ->
  unit ->
  (Llm_provider.Llm_transport.t option, Agent_sdk.Error.sdk_error) result

(** kimi_cli print-mode transport.  Re-exported via [module type of] from
    {!Oas_worker_exec.Kimi_cli_transport_local}. *)
module Kimi_cli_transport_local : sig
  type config = {
    kimi_path : string;
    model : string option;
    cwd : string option;
    config_json : string option;
    mcp_config_json : string list;
    extra_env : (string * string) list;
    cancel : unit Eio.Promise.t option;
  }

  val default_config : config

  (** Build the kimi_cli argv from a config + per-call request, deciding
      whether the prompt goes via [-p] or stdin. Non-ASCII or large prompts
      use stdin to avoid Kimi CLI macOS setproctitle UTF-8 decode crashes. *)
  val build_args :
    config:config ->
    req_config:Llm_provider.Provider_config.t ->
    mcp_config_json:string list ->
    prompt:string ->
    string list

  (** Whether a kimi_cli stderr line should be forwarded to the default
      stderr logger.  Drops the [resume hint] lines, which are noise. *)
  val should_log_stderr_line : string -> bool

  (** Constant detail string used when [kimi_cli] reports a resumable session
      without an embedded exit code. *)
  val resumable_session_detail : string

  (** Whether [text] looks like a resumable-session report from kimi_cli. *)
  val text_looks_like_resumable_session : string -> bool

  (** Render the resumable-session detail message for [text].  Includes the
      embedded exit code when one can be parsed; otherwise returns
      {!resumable_session_detail}. *)
  val resumable_session_detail_of_text : string -> string

  (** Parse the embedded exit code from a resumable-session [text].  Returns
      [Some 75] for the canonical case and [Some 1] when the payload only
      carries the resume hint. *)
  val resumable_session_exit_code_of_text : string -> int option

  (** Reclassify a [NetworkError] from kimi_cli into [AcceptRejected] when
      the message indicates a permanent per-provider error
      (auth/config/model), a local CLI startup crash, or a resumable-session
      report.  Other variants pass through. *)
  val classify_cli_error :
    ('a, Llm_provider.Http_client.http_error) result ->
    ('a, Llm_provider.Http_client.http_error) result

  (** Create a kimi_cli completion transport bound to [sw].  The transport
      runs [kimi --print --output-format stream-json ...] via [mgr] and
      parses JSONL output into OAS response/event blocks. *)
  val create :
    sw:Eio.Switch.t ->
    mgr:_ Eio.Process.mgr ->
    config:config ->
    Llm_provider.Llm_transport.t
end
