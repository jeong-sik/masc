(** Deterministic error recovery field generation.

    Pure logic for extracting structured recovery plans from
    deterministic failure payloads. No mutable state.

    @since P3 extraction *)

type deterministic_recovery_plan_parse_error =
  | Deterministic_recovery_plan_json_decode_error of string

val deterministic_recovery_plan_parse_error_to_string :
  deterministic_recovery_plan_parse_error -> string

val deterministic_recovery_plan_fields_result :
  string ->
  ((string * Yojson.Safe.t) list, deterministic_recovery_plan_parse_error) result
(** Result API for recovery-plan promotion. Malformed raw JSON is distinct from
    a valid payload that simply has no [recovery_plan]. *)

(** Promote a tool-specific [recovery_plan] out of a deterministic
    failure payload so the next call can route without scraping nested
    detail text. Compatibility projection of
    {!deterministic_recovery_plan_fields_result}. *)
val deterministic_recovery_plan_fields : string -> (string * Yojson.Safe.t) list
