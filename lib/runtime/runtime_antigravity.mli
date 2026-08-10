(** A single-turn Antigravity CLI client.

    This is an official-client runtime boundary, not an
    {!Llm_provider.Llm_transport}. Antigravity owns its OAuth session, model
    turn, and built-in tools. *)

type effort =
  | Low
  | Medium
  | High

type execution_mode =
  | Plan
  | Accept_edits

type config =
  { cli_path : string
  ; cwd : string
  ; model : string
  ; agent : string option
  ; effort : effort option
  ; execution_mode : execution_mode
  ; sandbox : bool
  ; disable_slash_commands : bool
  ; timeout_s : float
  }

val default_config : cwd:string -> model:string -> config

type conversation_mode =
  | Start
  | Resume of { conversation_id : string }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; thinking_tokens : int
  ; cache_read_tokens : int
  ; total_tokens : int
  }

type permission_mode = Always_proceed

type turn_result =
  { conversation_id : string
  ; model : string
  ; text : string
  ; num_turns : int
  ; usage : usage
  ; permission_mode : permission_mode
  ; tool_steps : int
  ; tool_errors : int
  ; resumed : bool
  ; wall_duration_s : float
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | State_callback_failed of string
  | Turn_failed of string
  | Process_exited of string
  | Timeout of float

val error_to_string : error -> string

val validate_turn :
  ?conversation_mode:conversation_mode ->
  config ->
  prompt:string ->
  (unit, error) result

val run_turn :
  ?conversation_mode:conversation_mode ->
  ?home_dir:string ->
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?on_conversation_ready:(conversation_id:string -> (unit, string) result) ->
  config ->
  prompt:string ->
  (turn_result, error) result
(** [home_dir], when present, replaces inherited [HOME] and removes inherited
    XDG directory overrides before spawning the official client. *)
