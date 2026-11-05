(** Partial consumer-schema guard for Exact Output. This is
    not a JSON Schema validator. The consumer still validates its full dialect. *)
type issue = Missing_required_key of string | Incompatible_required_shape of string
val issue : at:string -> Yojson.Safe.t -> Yojson.Safe.t -> issue option
(** Check visited object required keys, primitive types and anyOf alternatives.
    References, array items, enums and other keywords are not validated here. *)
val to_string : issue -> string
