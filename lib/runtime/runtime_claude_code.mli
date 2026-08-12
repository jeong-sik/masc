(** A single-turn client for the official Claude Code CLI.

    This is not an Anthropic HTTP provider and it does not read API keys.
    Claude Code owns the subscription session and model loop. MASC owns the
    child lifetime, exact SDK-control/MCP bridge, and terminal projection. *)

type subscription = private
  { auth_method : string
  ; subscription_type : string
  ; api_provider : string
  }

type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; system_prompt : string option
  ; admission_timeout_s : float
    (** Finite bound for the post-spawn initialize exchange and callbacks
        before the user turn is written. *)
  ; timeout_s : float option
    (** [None] removes the deadline after the user message is written: the
        spawned client decides when its own turn ends. Initialization remains
        bounded by [admission_timeout_s]. Declared as [turn-timeout-s] in
        runtime config, where [0] selects [None]. *)
    (** Maximum silence between CLI stream messages. Each received message
        resets the deadline; a progressing turn has no wall limit. *)
  }

val default_timeout_s : float
val default_config : cwd:string -> config

type session_mode =
  | Start
  | Resume of { session_id : string }

type rate_limit_status =
  | Allowed
  | Allowed_warning
  | Rejected

val rate_limit_status_to_string : rate_limit_status -> string

type rate_limit =
  { status : rate_limit_status
  ; rate_limit_type : string option
  ; resets_at : int option
  ; overage_status : string option
  ; overage_disabled_reason : string option
  }

type turn_usage =
  { input_tokens : int
  ; output_tokens : int
  }

type turn_result =
  { session_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; dynamic_tool_calls : int
  ; subscription : subscription
  ; rate_limit : rate_limit option
  ; resumed : bool
  ; usage : turn_usage option
  }

type dynamic_tool_result = Runtime_official_client_tool.dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : string option
  }

type dynamic_tool = Runtime_official_client_tool.dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

type stream_event =
  | Turn_started of
      { turn_id : string
      ; model : string
      }
  | Text_delta of string
  | Dynamic_tool_started of
      { call_id : string
      ; tool_name : string
      ; arguments : Yojson.Safe.t
      }
  | Dynamic_tool_finished of { call_id : string }
  | Turn_finished of { text : string }

val dynamic_tool_bytes : dynamic_tool list -> int
(** Bytes the tool declarations occupy in the request this process builds. Not
    provider tokens: it bounds the request, it does not price it. *)

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Subscription_required of string
  | Unsupported_control_request of string
  | Turn_transport_interrupted of
      { stage : string
      ; tool_effect_attempted : bool
      ; detail : string
      }
  | Context_window_exceeded of
      { message : string
      ; tool_effect_attempted : bool
      ; response_emitted : bool
      }
  | Turn_failed of string
  | Quota_blocked of
      { api_error_status : int option
      ; rate_limit : rate_limit option
      }
  | Process_exited of string
  | Timeout of float

val error_to_string : error -> string

val validate_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?session_mode:session_mode ->
  config ->
  prompt:string ->
  (unit, error) result

val bounded_subscription_probe_config
  :  fallback_timeout_s:float
  -> config
  -> config
(** Preserve an existing finite bound, or give an unbounded model turn a
    finite authentication-preflight fallback. *)

val probe_subscription :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config ->
  (subscription, error) result
(** Measure the official CLI login without submitting a model turn. The child
    receives the same credential-scrubbed environment as [run_turn]. *)

val run_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?reasoning_effort:Llm_provider.Reasoning_effort.t ->
  ?session_mode:session_mode ->
  ?admitted_subscription:subscription ->
  ?on_spawned:(unit -> unit) ->
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?on_session_ready:(session_id:string -> (unit, string) result) ->
  ?on_turn_starting:(session_id:string -> (unit, string) result) ->
  ?on_turn_started:(session_id:string -> turn_id:string -> (unit, string) result) ->
  ?on_stream_event:(stream_event -> unit) ->
  config ->
  prompt:string ->
  (turn_result, error) result
(** Execute one turn through Claude Code's stream-json control protocol.

    API-key and token environment variables are removed from the child. The
    preflight requires [claude auth status --json] to report a logged-in
    [claude.ai] subscription served by [firstParty]. *)
