(** Runtime_vibe_headless — decoder for Mistral Vibe headless output.

    [vibe -p] writes its result in two places. Stdout carries the session
    entries, as one JSON array ([--output json]) or one JSON object per line
    ([--output streaming]). [--output-dir] gets [export.json], the run's
    outcome, usage and exit code. This module turns both into closed types.
    It reads strings only; it spawns nothing and holds no state.

    The contract is what Vibe 3.1.0 wrote in the runs retained under
    [docs/evidence/vibe-official-client-lane-20261107/]. Vibe documents
    these files only in outline, so every enum decodes to a closed variant
    with one [Unrecognized_*] arm that keeps the wire value: a value a later
    Vibe adds is reported as itself and never taken for a value MASC knows.
    Fields Vibe adds are ignored. A required field that is missing or has
    another JSON type is an [Error]. *)

type error =
  { stage : string
  ; detail : string
  }

val error_to_string : error -> string

(** {1 export.json} *)

(** [export.json] [outcome]. The arms are the [RunOutcome] taxonomy of
    Vibe 3.1.0 ([vibe/app_server/run_export.py]). The [vibe -p] process is
    the Rust [vibe-rs]; this module assumes its export uses the same twelve
    strings. Observed in the retained runs: [finished],
    [usage_error], [infrastructure_failure], [deadline], [token_limit],
    [turn_limit]; the others are read from that source. *)
type outcome =
  | Finished
  | Usage_error
  | Config_error
  | Infrastructure_failure
  | Turn_limit
  | Token_limit
  | Price_limit
  | Deadline
  | Terminated
  | Length
  | Refusal
  | Aborted
      (** The server on the other end of [--agent-socket] ended the run. *)
  | Unrecognized_outcome of string

val outcome_to_wire : outcome -> string
(** The string [export.json] carries; an unrecognized outcome gives back
    its own value. *)

val exit_code_of_outcome : outcome -> int option
(** The exit code Vibe's Python [RunOutcome.exit_code] gives each outcome:
    [0] finished; [1] the run could not start as asked ([usage_error],
    [config_error]); [2] infrastructure failed; [3] the agent stopped without
    finishing, on a limit or a refusal; [4] aborted. [None] for an
    unrecognized outcome. *)

(** [export.json] [stop_reason] when it is not [null]. Observed values:
    [interrupted], [limit]. *)
type stop_reason =
  | Interrupted
  | Limit
  | Unrecognized_stop_reason of string

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cached_input_tokens : int
  ; total_tokens : int
  }

(** [export.json] [error] when it is not [null]. [code] is [None] for a
    JSON [null] code (an unknown [--model] wrote one); a provider refusal
    arrived as [backend_error] with the provider's body in [message]. *)
type run_error =
  { message : string
  ; code : string option
  }

(** The fields a lane reads. [session_id], [usage], [cost_usd] and [steps]
    are [null] when the run ended before a session started ([usage_error],
    [deadline] in the retained runs). *)
type export =
  { outcome : outcome
  ; stop_reason : stop_reason option
  ; error : run_error option
  ; session_id : string option
  ; usage : usage option
  ; cost_usd : float option
  ; steps : int option
  ; vibe_version : string
  ; exit_code : int
  }

(** The [schema_version] this decoder reads. Any other version is an
    [Error]: the fields may mean something else. *)
val export_schema_version : int

val decode_export : string -> (export, error) result

(** {1 Session entries} *)

type role =
  | User
  | Assistant
  | Unrecognized_role of string

(** A message content part. Only [text] parts were observed. *)
type content_part =
  | Text of string
  | Unrecognized_part of string

(** An effect's [state.status]. Observed values: [completed], [failed]. *)
type effect_status =
  | Completed
  | Failed
  | Unrecognized_effect_status of string

(** An effect's [state.error.code]. Only [tool_denied] was observed: the
    approval callback refused the call, as [ask] does for a call it would
    prompt for. *)
type effect_error_code =
  | Tool_denied
  | Unrecognized_effect_error of string

type effect_error =
  { code : effect_error_code
  ; message : string
  }

type entry =
  | Message of
      { session_id : string
      ; turn_id : string
      ; role : role
      ; content : content_part list
      }
  | Reasoning of
      { session_id : string
      ; turn_id : string
      ; text : string
      }
  | Effect of
      { session_id : string
      ; turn_id : string
      ; tool_name : string
      ; status : effect_status
      ; error : effect_error option
      }
  | Unrecognized_entry of
      { kind : string
      ; session_id : string
      ; turn_id : string
      }

(** [--output json] stdout: the session's entries, oldest first. *)
val decode_entries : string -> (entry list, error) result

(** One [--output streaming] stdout line. *)
val decode_streaming_line : string -> (entry, error) result
