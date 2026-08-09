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
  ; timeout_s : float
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

type turn_result =
  { session_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; dynamic_tool_calls : int
  ; subscription : subscription
  ; rate_limit : rate_limit option
  ; resumed : bool
  }

type dynamic_tool_result =
  { success : bool
  ; content : string
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

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

val probe_subscription :
  mgr:_ Eio.Process.mgr ->
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
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?on_session_ready:(session_id:string -> (unit, string) result) ->
  ?on_turn_starting:(session_id:string -> (unit, string) result) ->
  ?on_turn_started:(session_id:string -> turn_id:string -> (unit, string) result) ->
  config ->
  prompt:string ->
  (turn_result, error) result
(** Execute one turn through Claude Code's stream-json control protocol.

    API-key and token environment variables are removed from the child. The
    preflight requires [claude auth status --json] to report a logged-in
    [claude.ai] subscription served by [firstParty]. *)
