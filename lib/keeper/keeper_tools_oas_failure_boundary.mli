(** Pure failure-boundary classification for keeper tools wrapped as OAS tools.

    This module connects typed tool payloads to keeper retry policy. It only
    consumes structured JSON fields; free-form error text is not classified
    here. *)

type t =
  { failure_class : Tool_result.tool_failure_class
  ; is_workflow_rejection : bool
  ; deterministic_classification :
      Keeper_tool_deterministic_error.classification option
  ; parse_observations : parse_observation list
  }

and parse_observation =
  | Raw_failure_payload_json_decode_error of string
  | Structured_error_json_decode_error of string
  | Structured_error_json_non_object

val parse_observation_kind : parse_observation -> string
val parse_observation_to_json : parse_observation -> Yojson.Safe.t
val parse_observations_json : parse_observation list -> Yojson.Safe.t
val parse_observation_log_fields : t -> (string * Yojson.Safe.t) list

(** Classify a failed raw tool payload.

    Missing or malformed [failure_class] defaults to [Runtime_failure] unless
    [error] itself is a structured JSON object serialized as a string. A
    deterministic retry-skip is honored only when the structured payload is not
    retryable, so contradictory
    [failure_class="transient_error"] payloads stay non-deterministic. *)
val classify_raw_failure : string -> t
