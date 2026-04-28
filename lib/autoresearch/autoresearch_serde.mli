(** Autoresearch_serde — JSON serialization for autoresearch types.

    Re-exports the type SSOT from {!Autoresearch_types} via
    [include module type of] and adds typed converters between those
    domain records and [Yojson.Safe.t]. The [_result]-suffixed
    decoders return [(T, string) result] so callers can surface
    legacy-schema and parse failures verbatim.

    Internal field-extraction helpers ([required_string_field],
    [optional_int_field], etc.) and the [field_error] /
    [yojson_type_name] diagnostic builders are hidden — they exist
    only to keep the converter bodies short.

    @since 2.80.0 *)

include module type of Autoresearch_types

(** {1 Enum string conversions} *)

val decision_to_string : decision -> string
(** ["keep"] / ["discard"]. *)

val decision_of_string_result : string -> (decision, string) result

val status_to_string : status -> string
(** ["running"] / ["completed"] / ["stopped"] / ["error"]. *)

val status_of_string_result : string -> (status, string) result

(** {1 JSON converters} *)

val cycle_to_yojson : cycle_record -> Yojson.Safe.t
val cycle_of_yojson_result : Yojson.Safe.t -> (cycle_record, string) result

val state_to_yojson : loop_state -> Yojson.Safe.t

val state_of_yojson_result :
  Yojson.Safe.t -> (persisted_summary, string) result
(** Decoded shape is the persisted summary record (a wider view than
    [loop_state]), so callers can lift the [updated_at] back-fill in
    {!Autoresearch_storage.load_state_result}. *)

val execution_link_to_yojson : execution_link -> Yojson.Safe.t

val execution_link_of_yojson_result :
  Yojson.Safe.t -> (execution_link, string) result
