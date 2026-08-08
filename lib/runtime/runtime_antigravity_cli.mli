(** Official Antigravity CLI one-turn boundary.

    Antigravity owns its model/tool loop and subscription credentials. MASC
    owns argv construction, process lifetime, strict NDJSON decoding, session
    identity, and measured usage projection. This initial boundary is fixed to
    [plan + sandbox]; it never passes the dangerous permission-bypass flag. *)

type config =
  { cli_path : string
  ; cwd : string
  ; model : string option
  ; timeout_s : float
  }

type session_mode =
  | Start
  | Resume of { conversation_id : string }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; thinking_tokens : int
  ; cache_read_tokens : int
  ; total_tokens : int
  }

type turn_result =
  { conversation_id : string
  ; model : string
  ; text : string
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
  | Turn_failed of string
  | Process_exited of string
  | Timeout of float

val error_to_string : error -> string

val validate_run :
  ?session_mode:session_mode ->
  config ->
  prompt:string ->
  (unit, error) result
(** Validate the exact process boundary before a caller persists an execution
    claim. [run_turn] delegates to this same function. *)

val run_turn :
  ?session_mode:session_mode ->
  config ->
  prompt:string ->
  (turn_result, error) result

module For_testing : sig
  val parse_output :
    expected_model:string option ->
    expected_cwd:string ->
    session_mode:session_mode ->
    string ->
    (turn_result, error) result
end
