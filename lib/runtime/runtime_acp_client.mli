(** Unified persistent ACP v1 (Agent Client Protocol) JSON-RPC 2.0 over stdio
    client for official subscription CLIs: Antigravity ([agy acp]), Kimi Code
    ([kimi acp]), Mistral Vibe ([vibe-acp]), and Muse Code ([muse acp]).

    Each client value owns one persistent child process bound to a per-Keeper
    [Eio.Switch.t], amortizing CLI cold start across turns while keeping crash
    and stall blast radius strictly isolated to a single Keeper. *)

(** {1 Closed driver algebra} *)

type driver =
  | Antigravity
  | Kimi_code
  | Mistral_vibe
  | Muse_code
[@@deriving show, eq]

val all_drivers : driver list
val driver_to_string : driver -> string
val driver_of_string : string -> driver option

type model_selection = private
  | Keep_cli_default
  | Explicit_model of string
[@@deriving show, eq]

val keep_cli_default : model_selection
(** Keep the ACP CLI's active default model without issuing [session/set_model]
    or [session/set_config_option]. *)

val model_selection_of_string : string -> model_selection
(** Parse a configured ACP model identifier at the config boundary: empty strings
    and case-insensitive ["default"] become {!Keep_cli_default}; every other
    non-empty trimmed identifier becomes {!Explicit_model}. *)

val model_selection_to_string : model_selection -> string
(** Canonical diagnostic string for {!model_selection} (["default"] for
    {!Keep_cli_default}, the model id for {!Explicit_model}). *)

val effort_of_driver_string : driver:driver -> string -> Llm_provider.Reasoning_effort.t option
(** Parse a reasoning effort string at the TOML or ACP wire boundary using a
    single driver-scoped alias table: accepts the 8 canonical
    {!Llm_provider.Reasoning_effort} values for every driver, plus ["off"]
    as {!Llm_provider.Reasoning_effort.None_} exclusively for {!Mistral_vibe}
    (live-verified against [vibe-acp 3.1.0]; [agy acp 1.5.14] advertises
    [low/medium/high/xhigh] and [kimi acp 2.7.2] advertises [low/high/max]).
    [muse acp 1.4.25] advertises no effort option; its profile has no
    [effort_config_id] and the runtime.toml parser refuses [effort] for it. *)

val effort_values_for_log : driver:driver -> string
(** Human-readable list of effort values accepted by {!effort_of_driver_string}
    for [driver], suitable for startup validation error diagnostics. *)

val resolve_effective_effort
  :  ?turn_effort:Llm_provider.Reasoning_effort.t
  -> ?model_effort:Llm_provider.Reasoning_effort.t
  -> ?provider_effort:Llm_provider.Reasoning_effort.t
  -> unit
  -> Llm_provider.Reasoning_effort.t option
(** Canonical ACP reasoning-effort precedence shared across Keeper, Fusion, and
    Runtime Verification: [turn_effort > model_effort > provider_effort]
    (most-specific per-turn hook override, then binding/model declaration, then
    provider-wide ACP default). *)

type mcp_wiring =
  | Session_new_http_mcp
      (** Driver accepts [mcpServers] directly in [session/new] and
          [session/load] (Kimi Code, Mistral Vibe, Muse Code). *)
  | Gemini_dir_mcp_config
      (** Driver reads [<gemini_dir>/config/mcp_config.json] at startup and
          ignores ACP [mcpServers] (Antigravity [agy acp]). No [eager] map is
          emitted so all MASC tools stay on [agy]'s lazy list past its 62 KB
          eager ceiling. *)

type mcp_server_isolation =
  | Single_pinned_server of string
      (** Client process owns an isolated MCP configuration declaring ONLY
          the named MASC MCP server (Antigravity's private [--gemini-dir]
          with a single-entry [mcp_config.json]; live-verified against
          [agy acp 1.5.14] to ignore [<cwd>/.gemini/{settings,config/mcp_config}.json]
          while MASC sends [mcpServers = []] on [session/new]). An unqualified
          {!Implicit_mcp_kind} wire frame can only originate from that named
          pinned server. *)
  | Shared_or_multi_server
      (** Client process may attach additional host, plugin, or user-scoped
          MCP servers alongside MASC (e.g. [Session_new_http_mcp] drivers
          sharing operator [$HOME], or an Antigravity process started without
          a MASC-owned [mcp_config.json]). Unqualified {!Implicit_mcp_kind}
          frames cannot prove server provenance and MUST fail closed. *)
[@@deriving show, eq]

type system_prompt_channel =
  | Meta_antigravity_append
      (** Delivered via [_meta.antigravity.systemPrompt.append] in
          [session/new]. *)
  | Framed_in_first_prompt
      (** Prepended to the opening [session/prompt] turn. *)

type input_accounting =
  | Inclusive_of_cached
      (** Wire [inputTokens] already includes [cachedReadTokens] and
          [cachedWriteTokens] (e.g. Mistral Vibe, Kimi Code). *)
  | Exclusive_of_cached
      (** Wire [inputTokens] reports only uncached prompt tokens, excluding
          [cachedReadTokens] and [cachedWriteTokens] (e.g. Antigravity). *)

type output_accounting =
  | Inclusive_of_thought
      (** Wire [outputTokens] already includes [thoughtTokens] (e.g.
          Antigravity, Mistral Vibe, Kimi Code). *)
  | Exclusive_of_thought
      (** Wire [outputTokens] excludes [thoughtTokens]. *)

type usage_channel =
  | Usage_over_acp
      (** The host reports a prompt's token counts in the [session/prompt]
          result or in [usage_update] frames. *)
  | Usage_in_muse_session_journal
      (** The host reports none over ACP. It writes the counts of every model
          request and approval review to its session journal, which
          {!prompt} reads ({!Runtime_muse_session_log}). *)

type mcp_identifier_syntax =
  | Mcp_call_wrapper
      (** Structured [call_mcp_tool] wrapper carrying [ServerName]/[ToolName]
          in [rawInput] (Antigravity). *)
  | Mcp_paren_wrapper
      (** [mcp(<server>/<tool>)] or [mcp(<server>:<tool>)] wrapper
          (Antigravity). *)
  | Mcp_double_underscore
      (** [mcp__<server>__<tool>] identifier (live-verified against
          [kimi acp 2.7.2] and [muse acp 1.4.25]). *)
  | Mcp_dot_prefix
      (** [mcp_<server>.<tool>] identifier (Mistral Vibe). *)
  | Mcp_underscore_prefix
      (** [mcp_<server>_<tool>] identifier (Antigravity, Mistral Vibe). *)
  | Server_underscore_prefix
      (** [<server>_<tool>] identifier scoped to the active MASC server name
          (Mistral Vibe). *)
  | Implicit_vendor_mcp_kind
      (** Unqualified tool name paired with wire [kind = "mcp"]. *)
[@@deriving show, eq]

type driver_profile =
  { driver : driver
  ; default_command : string
  ; default_args : string list
  ; env_set : (string * string) list
  ; default_strip_env : string list
  ; mcp_wiring : mcp_wiring
  ; bridge_server_name : string
      (** The name of the MCP server the session carries, which the host puts
          in the names of its tools ([mcp__<server>__<tool>] for muse). Only
          [A-Za-z0-9_] and no [__]: hosts replace other characters in a tool
          name, and a name with [__] cannot be read back from it. *)
  ; mcp_identifier_syntaxes : mcp_identifier_syntax list
  ; system_prompt_channel : system_prompt_channel
  ; input_accounting : input_accounting
  ; output_accounting : output_accounting
  ; usage_channel : usage_channel
  ; supports_skills_dir_flag : bool
  ; mode_for_native_none : string
  ; mode_for_native_read : string
  ; mode_for_native_full : string
  ; model_config_id : string
  ; effort_config_id : string option
      (** ACP config option id that carries reasoning effort. [None] when the
          client takes effort only as a process setting ([muse acp]). *)
  }

val profile_of_driver : driver -> driver_profile

val bridge_server_name : driver -> string
(** The name the Keeper, runtime verification and the ACP probe give the MCP
    bridge they pass to the driver's host: [muse_code] uses [masc_keeper]
    because its host refuses a session server named like one in the
    operator's settings or a [.mcp.json] it loads, and an entry for MASC's
    own server can be named [masc]; the other drivers use [masc]. *)

val validate_session_effort :
  driver:driver -> Llm_provider.Reasoning_effort.t option -> (unit, string) result
(** Check whether the driver accepts a request to set reasoning effort on a session. *)
val mode_of_posture : driver -> Runtime_native_tools.posture -> string

val resolve_mode_for_posture
  :  driver:driver
  -> posture:Runtime_native_tools.posture
  -> configured_mode:string option
  -> string
(** Resolve the ACP session mode bounded by [posture]:
    - [Native_none] always enforces [mode_for_native_none].
    - [Native_read] permits [configured_mode] only when it matches the driver's
      declared [mode_for_native_none] or [mode_for_native_read]; any other
      value is clamped to [mode_for_native_read].
    - [Native_full] accepts any non-empty [configured_mode], defaulting to
      [mode_for_native_full]. *)

(** {1 Named protocol bounds} *)

val protocol_version : int
val default_timeout_s : float
val init_timeout_s : float

(** {1 Configuration & wire types} *)

type mcp_http_server =
  { name : string
  ; url : string
  ; headers : (string * string) list
  ; tool_names : string list
    (** The tools the server lists. [muse acp] is told to offer the server's
        tools only when this is non-empty: its tool list fails the first turn
        on a name that matches nothing, and a server that lists no tool
        matches nothing. *)
  }

val mcp_http_server_of_bridge : Runtime_official_client_mcp_http.t -> mcp_http_server
(** The server a host is started with for [bridge]. The name, URL, headers and
    tool names are all read from the bridge, so they cannot disagree with what
    the bridge serves. *)

type config =
  { driver : driver
  ; cli_path : string
  ; args : string list
  ; strip_env : string list
  ; skills_dirs : string list
  ; cwd : string
  ; oauth_source : string option
      (** Optional Antigravity OAuth token file; when [None] on Antigravity,
          the user's existing [~/.gemini/antigravity-cli] directory is linked
          into the managed [--gemini-dir] without mutating Keychains. *)
  ; dangerously_skip_permissions : bool
  ; admission_timeout_s : float
  }

val default_config : driver:driver -> cwd:string -> config

val install_client_of_driver : driver -> Runtime_official_cli_install.client
(** The official CLI install entry that locates a driver's executable. *)

type agent_capabilities =
  { load_session : bool
  ; resume_session : bool
  ; close_session : bool
  ; additional_directories : bool
  ; image_prompt : bool
  ; embedded_context : bool
  ; mcp_http : bool
  ; antigravity_system_prompt_append : bool
  ; antigravity_tier : string option
  }

type config_option =
  { id : string
  ; name : string
  ; category : string option
  ; current_value : string
  ; available_values : string list
  }

type session_info =
  { session_id : string
  ; current_mode_id : string option
  ; available_modes : string list
  ; current_model_id : string option
  ; available_models : string list
  ; config_options : config_option list
  ; antigravity_tier : string option
  ; replayed_context_used : int option
  ; replayed_context_size : int option
  }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cached_read_tokens : int
  ; cached_write_tokens : int
  ; thought_tokens : int
  ; total_tokens : int
  ; context_used : int option
  ; context_size : int option
  }

val empty_usage : usage

type normalized_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  }

val normalize_usage : driver -> usage -> normalized_usage
(** Convert wire {!usage} into canonical inclusive input/output token counts
    using the driver's declared {!input_accounting} and {!output_accounting},
    preventing double-counting of cached or thought tokens. *)

type stop_reason =
  | End_turn
  | Max_tokens
  | Max_turn_requests
  | Refusal
  | Cancelled
  | Other_stop_reason of string

val stop_reason_to_string : stop_reason -> string

type prompt_block =
  | Text_block of string
  | Image_block of
      { mime_type : string
      ; base64_data : string
      }

(** Official ACP v1 [ToolKind] wire enum plus vendor ["mcp"] extension and
    diagnostic {!Tool_unknown}. Security policies treat {!Tool_unknown} as
    highest-restriction (always denied and effect-fenced). *)
type tool_kind =
  | Tool_read
  | Tool_edit
  | Tool_delete
  | Tool_move
  | Tool_search
  | Tool_execute
  | Tool_think
  | Tool_fetch
  | Tool_switch_mode
  | Tool_other
  | Tool_vendor_mcp
  | Tool_unknown of string
[@@deriving show, eq]

val tool_kind_of_string : string -> tool_kind
val tool_kind_to_string : tool_kind -> string

type mcp_server_qualifier =
  | Explicit_server of string
      (** Wire payload explicitly named an MCP server using a syntax declared
          in the active driver's {!driver_profile.mcp_identifier_syntaxes} or
          structured [_meta]. *)
  | Implicit_mcp_kind
      (** Wire payload declared ACP tool kind {!Tool_vendor_mcp} with an
          unqualified tool name. *)

type tool_call_identity =
  | Mcp_tool of
      { server : mcp_server_qualifier
      ; tool_name : string
      }
  | Managed_mcp_schema_read of
      { mcp_server_name : string
      ; path : string
      }
      (** Read-only lazy MCP schema file lookup strictly inside this client's
          MASC-managed [<gemini_dir>/antigravity-cli/mcp/<server>] directory. *)
  | Native_tool of
      { name : string option
      ; kind : tool_kind option
      ; locations : string list
      }

type tool_call_status =
  | Tool_pending
  | Tool_in_progress
  | Tool_completed
  | Tool_failed
  | Tool_other_status of string

type stream_event =
  | Text_delta of string
  | Thought_delta of string
  | Tool_call_started of
      { tool_call_id : string
      ; title : string
      ; kind : tool_kind option
      ; status : tool_call_status
      ; raw_input : Yojson.Safe.t option
      ; identity : tool_call_identity
      }
  | Tool_call_updated of
      { tool_call_id : string
      ; title : string option
      ; kind : tool_kind option
      ; status : tool_call_status option
      ; raw_input : Yojson.Safe.t option
      ; raw_output : Yojson.Safe.t option
      ; identity : tool_call_identity option
      }
      (** Incremental [tool_call_update] notification: [title], [status], and
          [raw_output] reflect the update frame's own delta fields, whereas
          [kind], [raw_input], and [identity] reflect the monotonically merged
          [tool_call] + [tool_call_update] wire state ([identity = None] only
          when neither tracked prior state nor this frame carries identity
          fields). *)
  | Usage_updated of
      { used : int option
      ; size : int option
      ; prompt_tokens : int option
      ; completion_tokens : int option
      ; cached_tokens : int option
      ; cached_write_tokens : int option
      ; thought_tokens : int option
      ; total_tokens : int option
      }
  | Mode_updated of string
  | Config_options_updated of config_option list

type permission_policy =
  | Allow_all
  | Allow_masc_mcp_only of
      { mcp_server_name : string
      ; allowed_tool_names : string list
      }
  | Allow_read_and_masc_mcp of
      { mcp_server_name : string
      ; allowed_tool_names : string list
      }
  | Deny_all

val permission_policy_of_posture
  :  mcp_server_name:string
  -> allowed_tool_names:string list
  -> Runtime_native_tools.posture
  -> permission_policy

val should_allow_tool_call
  :  ?server_isolation:mcp_server_isolation
  -> policy:permission_policy
  -> tool_call_identity
  -> bool
(** Pure total permission decision over the closed {!tool_call_identity}
    variant. [server_isolation] defaults fail-closed to
    {!Shared_or_multi_server}, which rejects unqualified {!Implicit_mcp_kind}
    calls unless the caller proves {!Single_pinned_server} isolation from a
    live client handle via {!mcp_server_isolation}. *)

val is_masc_mcp_tool
  :  driver:driver
  -> mcp_server_name:string
  -> allowed_tool_names:string list
  -> title:string
  -> kind:tool_kind option
  -> bool
(** Strict membership predicate for callers that only hold [(driver, title, kind)].
    Evaluates fail-closed under {!Shared_or_multi_server} (rejecting unqualified
    {!Implicit_mcp_kind} because no live isolated client handle is presented).
    Prefer matching on {!tool_call_identity} from {!Tool_call_started} with
    {!mcp_server_isolation} from the live client handle. *)

val is_read_only_tool_kind : tool_kind option -> bool
(** True for read-only local ACP tool kinds ({!Tool_read}, {!Tool_search},
    {!Tool_think}). Network {!Tool_fetch}, {!Tool_switch_mode},
    {!Tool_unknown}, and [None] are excluded so [Native_read] cannot bypass
    egress/SSRF or mode-switch boundaries. *)

(** Where [prompt_result.usage] came from. *)
type usage_source =
  | Usage_from_acp
      (** What the host sent over ACP. A host with no token counts there
          leaves them zero. *)
  | Usage_from_muse_journal of Runtime_muse_session_log.turn
      (** The token counts of the host's journal replace the ones in [usage];
          the context window stays the one the host sent over ACP, except
          that the input of the last request stands in for an occupancy the
          host did not send. The turn keeps the split between the model
          requests and the approval reviews that [usage] adds up. *)
  | Usage_unreadable of Runtime_muse_session_log.error
      (** The host's profile says its counts are in its journal and they could
          not be read. [usage] holds what the host sent over ACP, which for
          the Muse host is no token count at all. *)

type prompt_result =
  { session_id : string
  ; stop_reason : stop_reason
  ; text : string
  ; thought : string
  ; usage : usage
  ; usage_source : usage_source
  ; tool_calls_observed : int
  ; wall_duration_s : float
  }

type error =
  | Invalid_config of string
  | Spawn_refused of Process_eio.spawn_refusal
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_name : string
      ; code : int
      ; message : string
      ; data : Yojson.Safe.t option
      ; refusal : Llm_provider.Retry.signal_refusal option
      }
  | Timeout of
      { stage : string
      ; timeout_s : float
      }
  | Process_exited of
      { detail : string
      ; stderr_tail : string
      }
  | Client_closed

val error_to_string : error -> string

val rpc_error
  :  method_name:string
  -> code:int
  -> message:string
  -> data:Yojson.Safe.t option
  -> error
(** Decode provider refusal evidence at the RPC boundary. An HTTP status in
    [code] takes precedence over structured [data]. A string-valued [data]
    must be a complete JSON object or array. [message] is diagnostic text. *)

type jsonrpc_code =
  | Jsonrpc_parse_error
  | Jsonrpc_invalid_request
  | Jsonrpc_method_not_found
  | Jsonrpc_invalid_params
  | Jsonrpc_internal_error
  | Jsonrpc_server_error of int
  | Jsonrpc_http_status of int
  | Jsonrpc_other_code of int

val jsonrpc_code_of_int : int -> jsonrpc_code
(** Partition a JSON-RPC 2.0 error integer into its closed wire taxonomy so
    negative JSON-RPC protocol/server codes ([-32700..-32000]) are never
    conflated with HTTP refusal statuses ([400..599]). *)

val image_input_unsupported_detail : driver -> string
(** Canonical refusal detail when an ACP server advertises
    [agentCapabilities.promptCapabilities.image = false]. *)

val validate_prompt_blocks
  :  driver:driver
  -> capabilities:agent_capabilities
  -> prompt_block list
  -> (unit, error) result
(** Gate [Image_block] emission on [capabilities.image_prompt] and validate
    image media types and base64 payloads via
    {!Runtime_official_client_tool.validate_image_inputs} before sending JSON-RPC. *)

(** {1 Persistent client handle} *)

type t

val foreground_process_mgr
  :  clock:_ Eio.Time.clock
  -> ?grace_seconds:float
  -> unit
  -> Eio_unix.Process.mgr_ty Eio.Resource.t
(** Build a process-group-isolated {!Posix_spawn_process_mgr} foreground process
    manager suitable for {!start}, ensuring ACP subprocesses and any spawned
    grandchildren are reaped via [killpg SIGTERM -> grace -> SIGKILL]. *)

val create_isolated_workspace
  :  sw:Eio.Switch.t
  -> ?prefix:string
  -> unit
  -> (string, error) result
(** Create a canonicalized, [0700], PID-tagged empty workspace directory bound
    to [sw] (removed automatically on switch release). Use as ACP [cwd] for
    [Native_none] / [Deny_all] turns so official CLIs that auto-allow reads
    inside [cwd] can never access workspace state or [.masc/]. *)

val start
  :  sw:Eio.Switch.t
  -> proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> ?fs:Eio.Fs.dir_ty Eio.Path.t
  -> config:config
  -> ?mcp_server:mcp_http_server
  -> ?native_posture:Runtime_native_tools.posture
  -> unit
  -> (t, error) result
(** Spawn the persistent ACP CLI child under [sw], register cleanup on [sw],
    and complete the ACP v1 [initialize] handshake. When [fs] is supplied, the
    child's working directory is resolved directly via [fs / config.cwd]
    without requiring a global [Eio_context]. When [native_posture] is
    supplied, Antigravity [settings.json] enforces posture-specific write,
    command, and [cwd] read denies and Kimi suppresses [--skills-dir] under
    [Native_none]. [muse acp] is started with [-c run.toolset] naming the
    tools [native_posture] allows and, when [mcp_server] lists any tool, the
    tools of that server; the host runs some native tools without a
    permission request, so refusing requests could not keep them off. *)

val driver : t -> driver
val mcp_server_isolation : t -> mcp_server_isolation
(** Effective MCP server isolation proven for this live client handle
    ({!Single_pinned_server} only when MASC materialized an isolated single-entry
    [--gemini-dir/config/mcp_config.json]; {!Shared_or_multi_server} otherwise). *)
val capabilities : t -> agent_capabilities
val init_latency_ms : t -> int
val is_alive : t -> bool
val stderr_tail : t -> string
(** Recent child stderr output, UTF-8-safe bounded and redacted with
    {!Secret_patterns.redact_text} plus any configured MCP server header
    secrets. *)

val new_session
  :  t
  -> cwd:string
  -> ?system_prompt_append:string
  -> ?mcp_server:mcp_http_server
  -> ?additional_directories:string list
  -> ?mode:string
  -> ?model:model_selection
  -> ?effort:Llm_provider.Reasoning_effort.t
  -> unit
  -> (session_info, error) result

val load_session
  :  t
  -> session_id:string
  -> cwd:string
  -> ?mcp_server:mcp_http_server
  -> ?additional_directories:string list
  -> ?mode:string
  -> ?model:model_selection
  -> ?effort:Llm_provider.Reasoning_effort.t
  -> unit
  -> (session_info, error) result
(** Load an existing ACP session with activity-based idle liveness across
    replayed [session/update] notifications, capturing replayed context usage,
    mode, and config options into the returned {!session_info}. *)

val resume_session
  :  t
  -> session_id:string
  -> cwd:string
  -> ?mcp_server:mcp_http_server
  -> ?additional_directories:string list
  -> ?mode:string
  -> ?model:model_selection
  -> ?effort:Llm_provider.Reasoning_effort.t
  -> unit
  -> (session_info, error) result

val reconfigure_session
  :  t
  -> session_info
  -> ?mode:string
  -> ?model:model_selection
  -> ?effort:Llm_provider.Reasoning_effort.t
  -> unit
  -> (session_info, error) result
(** Idempotently apply [mode], [model], and [effort] deltas to an already-open
    session. Sends zero RPCs when the desired values already match [session_info]. *)

val close_session : ?timeout_s:float -> t -> session_id:string -> (unit, error) result
(** Invoke ACP [session/close] to release server-side state for [session_id].
    Defaults to {!init_timeout_s}; pass a smaller [timeout_s] on ephemeral
    one-shot clients so teardown never blocks for 30s. *)

val set_mode : t -> session_id:string -> mode_id:string -> (unit, error) result

val set_model : t -> session_id:string -> model_id:string -> (unit, error) result
(** Invoke standard ACP [session/set_model] for drivers that advertise
    [models.availableModels] (e.g. Antigravity effort-qualified model IDs). *)

val set_config_option
  :  t
  -> session_id:string
  -> config_id:string
  -> value:string
  -> (config_option list, error) result

val note_activity : t -> unit
(** Refresh the client's monotonic activity timestamp for idle-liveness checks. *)

val with_external_activity : t -> (unit -> 'a) -> 'a
(** Bracket caller-owned work (such as executing a loopback MASC MCP tool call)
    so an active {!prompt} suspends its idle-silence deadline while the ACP
    child is waiting on MASC, and refreshes liveness upon completion. *)

val prompt
  :  t
  -> session_id:string
  -> blocks:prompt_block list
  -> ?timeout_s:float option
  -> ?permission_policy:permission_policy
  -> ?on_event:(stream_event -> unit)
  -> unit
  -> (prompt_result, error) result
(** Execute one [session/prompt] turn on an existing ACP session, streaming
    [session/update] notifications to [on_event] and answering server-initiated
    [session/request_permission] requests according to [permission_policy].
    [timeout_s] bounds inactivity (time with no session-matched ACP frames and
    no in-flight {!with_external_activity} work) rather than cutting off
    actively progressing multi-tool turns. Cancelling the calling fiber or
    hitting the idle deadline sends [session/cancel]. *)

val cancel : t -> session_id:string -> unit
(** Send a best-effort [session/cancel] notification for [session_id]. *)

val close : t -> unit
(** Gracefully close stdin and stop the persistent child process. Idempotent. *)

(** {1 Pure helpers exposed for testing} *)

module For_testing : sig
  val build_environment
    :  base_env:string array
    -> driver:driver
    -> extra_strip_env:string list
    -> string array

  val build_argv
    :  ?native_posture:Runtime_native_tools.posture
    -> ?mcp_server:mcp_http_server
    -> config
    -> temp_gemini_dir:string option
    -> string list
  val utf8_safe_suffix : max_bytes:int -> string -> string
  val redact_stderr_text : ?extra_secrets:string list -> string -> string
  val should_allow_permission
    :  driver:driver
    -> policy:permission_policy
    -> title:string
    -> kind:tool_kind option
    -> bool

  val classify_tool_call_json
    :  driver:driver
    -> ?managed_schema_root:string * string
    -> ?mcp_server_name:string
    -> Yojson.Safe.t
    -> tool_call_identity

  val merge_tool_kind : prior:tool_kind option -> incoming:tool_kind option -> tool_kind option
  val choose_permission_option : allow:bool -> Yojson.Safe.t list -> string option
  val parse_config_options : Yojson.Safe.t -> config_option list
  val parse_session_info : Yojson.Safe.t -> (session_info, string) result

  val resolve_model_option_value
    :  driver:driver
    -> requested:model_selection
    -> option:config_option
    -> string option

  val resolve_effort_option_value
    :  driver:driver
    -> requested:Llm_provider.Reasoning_effort.t
    -> option:config_option
    -> string option

  val parse_session_update : driver:driver -> Yojson.Safe.t -> stream_event option
  val parse_prompt_usage : Yojson.Safe.t -> usage
  val parse_stop_reason : string -> stop_reason
  val max_prompt_stream_bytes : int
end
