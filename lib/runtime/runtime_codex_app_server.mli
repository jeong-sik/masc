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
  ; cwd : string
  ; model : string option
  ; developer_instructions : string option
  ; timeout_s : float
  }

val default_config : cwd:string -> config

type turn_result =
  { thread_id : string
  ; turn_id : string
  ; model : string
  ; text : string
  ; subscription : subscription
  ; user_agent : string option
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

val run_turn :
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  config ->
  prompt:string ->
  (turn_result, error) result
