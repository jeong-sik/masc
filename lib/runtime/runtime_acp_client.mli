(** Unified persistent ACP v1 (Agent Client Protocol) JSON-RPC 2.0 over stdio
    client for official subscription CLIs: Antigravity ([agy acp]), Kimi Code
    ([kimi acp]), and Mistral Vibe ([vibe-acp]).

    Each client value owns one persistent child process bound to a per-Keeper
    [Eio.Switch.t], amortizing CLI cold start across turns while keeping crash
    and stall blast radius strictly isolated to a single Keeper. *)

(** {1 Closed driver algebra} *)

type driver =
  | Antigravity
  | Kimi_code
  | Mistral_vibe
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
    [low/medium/high/xhigh] and [kimi acp 2.7.2] advertises [low/high/max]). *)

val effort_values_for_log : driver:driver -> string
(** Human-readable list of effort values accepted by {!effort_of_driver_string}
    for [driver], suitable for startup validation error diagnostics. *)

type mcp_wiring =
  | Session_new_http_mcp
      (** Driver accepts [mcpServers] directly in [session/new] and
          [session/load] (Kimi Code, Mistral Vibe). *)
  | Gemini_dir_mcp_config
      (** Driver reads [<gemini_dir>/config/mcp_config.json] at startup and
          ignores ACP [mcpServers] (Antigravity [agy acp]). No [eager] map is
          emitted so all MASC tools stay on [agy]'s lazy list past its 62 KB
          eager ceiling. *)

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

type driver_profile =
  { driver : driver
  ; default_command : string
  ; default_args : string list
  ; env_set : (string * string) list
  ; default_strip_env : string list
  ; mcp_wiring : mcp_wiring
  ; system_prompt_channel : system_prompt_channel
  ; input_accounting : input_accounting
  ; output_accounting : output_accounting
  ; supports_skills_dir_flag : bool
  ; mode_for_native_none : string
  ; mode_for_native_read : string
  ; mode_for_native_full : string
  ; model_config_id : string
  ; effort_config_id : string option
  }

val profile_of_driver : driver -> driver_profile
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
  }

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

type mcp_server_qualifier =
  | Explicit_server of string
      (** Wire payload explicitly named an MCP server (e.g. Antigravity
          [call_mcp_tool] with [rawInput.ServerName], structured [_meta],
          [mcp__<srv>__<tool>], [mcp_<srv>.<tool>], [<srv>:<tool>],
          [<srv>/<tool>]). *)
  | Implicit_mcp_kind
      (** Wire payload declared ACP tool kind ["mcp"] with an unqualified tool
          name. *)

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
      ; kind : string option
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
      ; kind : string option
      ; status : tool_call_status
      ; raw_input : Yojson.Safe.t option
      ; identity : tool_call_identity
      }
  | Tool_call_updated of
      { tool_call_id : string
      ; title : string option
      ; status : tool_call_status option
      ; raw_output : Yojson.Safe.t option
      }
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

val should_allow_tool_call : policy:permission_policy -> tool_call_identity -> bool
(** Total permission decision over the closed {!tool_call_identity} variant. *)

val is_masc_mcp_tool
  :  mcp_server_name:string
  -> allowed_tool_names:string list
  -> title:string
  -> kind:string option
  -> bool
(** Strict membership predicate for callers that only hold [(title, kind)].
    Prefer matching on {!tool_call_identity} from {!Tool_call_started} so
    structured MCP calls and managed schema reads are classified without
    display-title inspection. *)

val is_read_only_tool_kind : string option -> bool
(** True for read-only local ACP tool kinds (["read"], ["search"], ["think"]).
    Network ["fetch"] is excluded so [Native_read] cannot bypass egress/SSRF boundaries. *)

type prompt_result =
  { session_id : string
  ; stop_reason : stop_reason
  ; text : string
  ; thought : string
  ; usage : usage
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

val is_context_overflow_rpc_error
  :  method_name:string
  -> code:int
  -> message:string
  -> data:Yojson.Safe.t option
  -> bool
(** True when an ACP JSON-RPC error reports a structured provider/model
    context-window or prompt-length overflow (via {!Llm_provider.Retry}) that
    should enter shrink/compaction recovery. Free-form prose without a
    structured JSON payload or exact wire code returns [false]. *)

type rpc_error_class =
  | Rpc_context_overflow of { limit : int option }
  | Rpc_request_body_too_large
  | Rpc_hard_quota of { retry_after : float option }
  | Rpc_rate_limited of { retry_after : float option }
  | Rpc_auth_error
  | Rpc_authorization_error
  | Rpc_provider_unavailable
  | Rpc_unclassified

val classify_rpc_error
  :  method_name:string
  -> code:int
  -> message:string
  -> data:Yojson.Safe.t option
  -> rpc_error_class
(** Classify an upstream ACP JSON-RPC error into a closed provider-refusal
    class by delegating strictly to {!Llm_provider.Retry}:
    1. structured JSON [data] ([Retry.classify_structured_json] /
       [Retry.classify_text]),
    2. unified text refusal classification on [message] ([Retry.classify_text]),
    under one HTTP status precedence gate combining {!Jsonrpc_http_status},
    [data] status fields, and explicit [HTTP <4xx|5xx>] tokens in [message] so
    HTTP [401]/[402]/[403]/[413]/[429]/[5xx] never downgrade into
    {!Rpc_context_overflow}. Free-form English prose without structured evidence
    returns {!Rpc_unclassified}. *)

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
    [Native_none]. *)

val driver : t -> driver
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
    -> config
    -> temp_gemini_dir:string option
    -> string list
  val utf8_safe_suffix : max_bytes:int -> string -> string
  val redact_stderr_text : ?extra_secrets:string list -> string -> string
  val should_allow_permission : policy:permission_policy -> title:string -> kind:string option -> bool

  val classify_tool_call_json
    :  ?managed_schema_root:string * string
    -> ?mcp_server_name:string
    -> Yojson.Safe.t
    -> tool_call_identity

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

  val parse_session_update : Yojson.Safe.t -> stream_event option
  val parse_prompt_usage : Yojson.Safe.t -> usage
  val parse_stop_reason : string -> stop_reason
  val max_prompt_stream_bytes : int
end
