(** A single-turn Codex app-server client.

    This is an agent-runtime boundary, not an {!Llm_provider.Llm_transport}
    implementation. Codex owns the whole turn. MASC owns process lifetime,
    subscription admission, and terminal projection. *)

type subscription =
  { plan_type : string
  ; email : string option
  }

type config =
  { cli_path : string
  ; model : string option
  ; developer_instructions : string option
  ; timeout_s : float
  }

val default_config : unit -> config

type thread_mode =
  | Start
  | Resume of { thread_id : string }

type turn_result =
  { thread_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; dynamic_tool_calls : int
  ; subscription : subscription
  ; user_agent : string option
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

type history_role =
  | User
  | Assistant

type history_message =
  { role : history_role
  ; text : string
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_ : string
      ; code : int option
      ; message : string
      }
  | Subscription_required of string
  | Unsupported_server_request of string
  | Turn_failed of string
  | Turn_interrupted
  | Process_exited of string
  | Timeout of float

val error_to_string : error -> string

val validate_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?thread_mode:thread_mode ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  config ->
  prompt:string ->
  (unit, error) result
(** Validate every deterministic client-side admission condition. Keeper calls
    this before it durably claims a session; [run_turn] repeats the same check
    at the process boundary. *)

val run_turn :
  ?dynamic_tools:dynamic_tool list ->
  ?reasoning_effort:Llm_provider.Reasoning_effort.t ->
  ?thread_mode:thread_mode ->
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?history:history_message list ->
  ?on_thread_ready:(thread_id:string -> (unit, string) result) ->
  ?on_turn_starting:(thread_id:string -> (unit, string) result) ->
  ?on_turn_started:(thread_id:string -> turn_id:string -> (unit, string) result) ->
  config ->
  prompt:string ->
  (turn_result, error) result
