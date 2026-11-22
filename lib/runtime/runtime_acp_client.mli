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
  ; config_options : config_option list
  ; antigravity_tier : string option
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

val is_masc_mcp_tool
  :  mcp_server_name:string
  -> allowed_tool_names:string list
  -> title:string
  -> kind:string option
  -> bool
(** Strict membership predicate: returns [true] only when [title] identifies a
    pinned MASC tool in [allowed_tool_names] on [mcp_server_name] and [kind] is
    not a native execution/mutation tool kind. *)

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

val is_context_overflow_rpc_error : method_name:string -> code:int -> message:string -> bool
(** True when an ACP JSON-RPC error reports a provider/model context-window or
    prompt-length overflow that should enter shrink/compaction recovery. *)

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

val start
  :  sw:Eio.Switch.t
  -> proc_mgr:[> [> `Generic ] Eio.Process.mgr_ty ] Eio.Resource.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> config:config
  -> ?mcp_server:mcp_http_server
  -> unit
  -> (t, error) result
(** Spawn the persistent ACP CLI child under [sw], register cleanup on [sw],
    and complete the ACP v1 [initialize] handshake. *)

val driver : t -> driver
val capabilities : t -> agent_capabilities
val init_latency_ms : t -> int
val is_alive : t -> bool
val stderr_tail : t -> string

val new_session
  :  t
  -> cwd:string
  -> ?system_prompt_append:string
  -> ?mcp_server:mcp_http_server
  -> ?additional_directories:string list
  -> ?mode:string
  -> ?model:string
  -> ?effort:string
  -> unit
  -> (session_info, error) result

val load_session
  :  t
  -> session_id:string
  -> cwd:string
  -> ?mcp_server:mcp_http_server
  -> ?mode:string
  -> ?model:string
  -> ?effort:string
  -> unit
  -> (session_info, error) result

val resume_session
  :  t
  -> session_id:string
  -> cwd:string
  -> ?mcp_server:mcp_http_server
  -> ?mode:string
  -> ?model:string
  -> ?effort:string
  -> unit
  -> (session_info, error) result

val set_mode : t -> session_id:string -> mode_id:string -> (unit, error) result

val set_config_option
  :  t
  -> session_id:string
  -> config_id:string
  -> value:string
  -> (config_option list, error) result

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
    Cancelling the calling fiber or hitting [timeout_s] sends [session/cancel]. *)

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

  val build_argv : config -> temp_gemini_dir:string option -> string list
  val should_allow_permission : policy:permission_policy -> title:string -> kind:string option -> bool
  val choose_permission_option : allow:bool -> Yojson.Safe.t list -> string option
  val parse_config_options : Yojson.Safe.t -> config_option list

  val resolve_option_value
    :  driver:driver
    -> config_id:string
    -> requested:string
    -> option:config_option
    -> string option

  val parse_session_update : Yojson.Safe.t -> stream_event option
  val parse_prompt_usage : Yojson.Safe.t -> usage
  val parse_stop_reason : string -> stop_reason
  val max_prompt_stream_bytes : int
end
