(** Official Claude Code CLI one-turn boundary.

    The official client owns model execution and its read-only tool loop. MASC
    owns argv construction, process lifetime, strict stream-json decoding, and
    exact session identity. The child inherits the user's existing Claude Code
    login; metered API credentials and endpoint overrides are removed. *)

type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; timeout_s : float
  ; max_turns : int
  }

type session_mode =
  | Start of { session_id : string }
  | Resume of { session_id : string }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; total_cost_usd : float
  }

type turn_result =
  { session_id : string
  ; model : string
  ; text : string
  ; num_turns : int
  ; usage : usage
  ; tool_calls : int
  ; permission_mode : string
  ; resumed : bool
  }

type rejection =
  { status : string
  ; reset_at : int option
  ; detail : string
  ; model : string
  ; num_turns : int
  ; usage : usage
  ; tool_calls : int
  ; permission_mode : string
  ; resumed : bool
  }

type error =
  | Invalid_config of string
  | Spawn_failed of string
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Turn_rejected of rejection
  | Turn_failed of string
  | Process_exited of string
  | Timeout of float

val error_to_string : error -> string

val validate_run : config -> session_mode:session_mode -> prompt:string -> (unit, error) result
(** Validate the exact process boundary before a caller persists an execution
    claim. [run_turn] delegates to this same function. *)

val run_turn : config -> session_mode:session_mode -> prompt:string -> (turn_result, error) result

module For_testing : sig
  val parse_output :
    expected_model:string option ->
    expected_cwd:string ->
    session_mode:session_mode ->
    string ->
    (turn_result, error) result

  val is_disallowed_environment_override : string -> bool
end
