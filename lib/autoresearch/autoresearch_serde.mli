(** Autoresearch_serde — JSON serialization for autoresearch types.

    Adds typed converters between the {!Autoresearch_types} domain
    records and [Yojson.Safe.t]. The type SSOT remains
    {!Autoresearch_types}; this module does not re-export it (an
    earlier [include module type of] copy generated nominally distinct
    record types and broke caller compilation). The
    [_result]-suffixed decoders return [(T, string) result] so callers
    can surface legacy-schema and parse failures verbatim.

    Internal field-extraction helpers ([required_string_field],
    [optional_int_field], etc.) and the [field_error] /
    [yojson_type_name] diagnostic builders are hidden — they exist
    only to keep the converter bodies short.

    @since 2.80.0 *)

(** {1 Enum string conversions} *)

val decision_to_string : Autoresearch_types.decision -> string
(** ["keep"] / ["discard"]. *)

val decision_of_string_result :
  string -> (Autoresearch_types.decision, string) result

val status_to_string : Autoresearch_types.status -> string
(** ["running"] / ["completed"] / ["stopped"] / ["error"]. *)

val status_of_string_result :
  string -> (Autoresearch_types.status, string) result

(** {1 JSON converters} *)

val cycle_to_yojson : Autoresearch_types.cycle_record -> Yojson.Safe.t

val cycle_of_yojson_result :
  Yojson.Safe.t -> (Autoresearch_types.cycle_record, string) result

val state_to_yojson : Autoresearch_types.loop_state -> Yojson.Safe.t

val state_of_yojson_result :
  Yojson.Safe.t -> (Autoresearch_types.persisted_summary, string) result
(** Decoded shape is the persisted summary record (a wider view than
    [loop_state]), so callers can lift the [updated_at] back-fill in
    {!Autoresearch_storage.load_state_result}. *)

val execution_link_to_yojson :
  Autoresearch_types.execution_link -> Yojson.Safe.t

val execution_link_of_yojson_result :
  Yojson.Safe.t -> (Autoresearch_types.execution_link, string) result
