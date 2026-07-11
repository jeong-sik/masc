(** Request-time output-token intent at the MASC -> OAS boundary. *)

type source =
  | Omitted
  | Explicit_override

val source_of_value : int option -> source
val source_to_string : source -> string

val telemetry_fields : int option -> (string * Yojson.Safe.t) list
(** Stable observability projection. [None] is [omitted], not
    [provider_default]: optional envelopes omit the field, while required
    envelopes may apply an OAS-owned catalog fallback. *)
