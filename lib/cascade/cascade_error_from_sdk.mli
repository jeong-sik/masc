(** Reverse-direction SDK envelope decoders for the [masc_internal_error] ADT.
    See {!Cascade_internal_error} for the forward codec.

    @since RFC-0142 Phase 2 *)

val parse_masc_internal_error_json :
  Yojson.Safe.t -> Cascade_internal_error.masc_internal_error option
(** Parse a JSON value produced by
    {!Cascade_internal_error.masc_internal_error_to_json} back into the
    [masc_internal_error] variant.  Returns [None] when the JSON shape does
    not match any known constructor. *)

val classify_masc_internal_error_of_string :
  string -> Cascade_internal_error.masc_internal_error option
(** Parse a [masc_internal_error] from a raw string that may contain the
    [[masc_oas_error]] prefix anywhere (e.g. embedded in a blocker text
    wrapper).  Returns [None] when the prefix is absent or the JSON payload
    is malformed. *)

val classify_masc_internal_error :
  Agent_sdk.Error.sdk_error -> Cascade_internal_error.masc_internal_error option
(** Parse an SDK error back into a [masc_internal_error] when it carries the
    [[masc_oas_error]] prefix, including wrapped [Internal] messages where the
    prefix is embedded inside a larger diagnostic.  Returns [None] when the
    prefix is absent or the JSON payload is malformed. *)
