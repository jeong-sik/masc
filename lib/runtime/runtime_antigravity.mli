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

val max_prompt_bytes : int
(** Largest prompt this runtime can spawn. The CLI has no stdin or file form
    for the prompt, so it travels as one command-line argument and is bounded
    by the kernel rather than by the provider. Callers that assemble a prompt
    from unbounded material must fit it to this budget and account for what
    they left out; [validate_turn] refuses anything larger. *)

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

type permission_mode =
  | Always_proceed
  | Request_review
  | Unrecognized_permission_mode of string
      (** A mode the CLI announced that this tree does not model. Nothing
          branches on [permission_mode], so an unseen member is carried rather
          than rejected: rejecting it ended the turn and parked the session. *)

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
  | Prompt_too_large of
      { bytes : int
      ; limit : int
      }
      (** The CLI takes the prompt as one command-line argument, so a prompt
          past the kernel's per-argument cap cannot be spawned at all. Refused
          here so the caller sees the size instead of an opaque
          [execve: Argument list too long] from the spawn. *)
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
