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
  ; add_dirs : string list
    (** Extra absolute workspace roots beside [cwd], each passed as its own
        [--add-dir]. Empty keeps [cwd] as the only root. *)
  ; model : string
  ; agent : string option
  ; effort : effort option
  ; execution_mode : execution_mode
  ; sandbox : bool
  ; disable_slash_commands : bool
  ; admission_timeout_s : float
    (** Finite bound for the post-spawn wait for the first [init] event and its
        admission callback. *)
  ; timeout_s : float option
    (** [None] removes the deadline after the first valid [init] event and its
        admission callback: the spawned client decides when its own turn ends.
        The post-spawn pre-init phase remains bounded by [admission_timeout_s].
        Declared as [turn-timeout-s] in runtime config, where [0] selects
        [None]. *)
    (** Maximum silence between valid stream-json messages. It is not a total
        turn-duration bound. *)
  ; wall_clock_ceiling_s : float option
    (** Whole-turn wall-clock ceiling measured from spawn ([None] selects the
        shared hours-scale default). The idle timeout above resets on every
        emitted line, so this is the only bound a turn of continuous thin
        progress cannot outlive (#31242). *)
  ; output_schema : Yojson.Safe.t option
    (** JSON Schema the CLI enforces on the turn's final answer
        ([--json-schema]). Validation with a re-prompt, not constrained
        decoding. Only the result event's [structured_output] carries the value
        that passed; the narrated response beside it can still hold a draft the
        schema rejects, so this adapter reports the structured value as the
        turn's text when the field is present. *)
  }

val default_config : cwd:string -> model:string -> config

type conversation_mode =
  | Start
  | Resume of { conversation_id : string }
(** [Start] asks the official client to create a new project so cached
    workspace state cannot select an earlier conversation. [Resume] names the
    exact durable conversation and never creates a project. *)

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; thinking_tokens : int
  ; cache_read_tokens : int
  ; total_tokens : int
  }
(** Counts exactly as the CLI reports them, which is an {b exclusive} prompt
    count: the parse accepts a frame only when
    [total_tokens = input_tokens + output_tokens], so [cache_read_tokens] is
    outside both. {!Agent_core.Types.api_usage.input_tokens} is the inclusive
    total instead, so a caller converting to it must add the cache components
    through [Backend_anthropic.usage_of_wire_counts] rather than copying the
    fields across. *)

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
  ; trajectory_error : string option
      (** The CLI marks the whole result [ERROR] when any trajectory step
          errored, even one the model corrected before replying. When a
          reply was produced the turn is complete and the step error is
          carried here; [None] for a clean [SUCCESS] result. *)
  ; resumed : bool
  ; wall_duration_s : float
  }

type stream_event =
  | Turn_started of
      { conversation_id : string
      ; model : string
      }
  | Text_delta of string
  | Native_tool_started of Runtime_native_tools.observation
  | Native_tool_finished of Runtime_native_tools.observation
  | Turn_finished of { text : string }

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
  ?on_spawned:(unit -> unit) ->
  mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  ?on_conversation_ready:(conversation_id:string -> (unit, string) result) ->
  ?on_stream_event:(stream_event -> unit) ->
  config ->
  prompt:string ->
  (turn_result, error) result
(** [home_dir], when present, replaces inherited [HOME] and removes inherited
    XDG directory overrides before spawning the official client. *)
