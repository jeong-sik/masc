(** Reading a connector REST response under one duplicate-key policy.

    JSON does not forbid a repeated object key and Yojson does not reject one,
    so without a policy the same body could give two answers depending on
    which field reader saw it. A repeated key is a property of the document,
    not of one field read, so {!parse} rejects such a body once, at any depth,
    for every connector. Every reader below is total on the result, so no call
    site holds a per-field error it has to decide about. *)

type t
(** A parsed connector response. No object in it repeats a key. *)

val parse : context:string -> string -> (t, string) result
(** Parse a response body. [Error] names the repeated key if any object in the
    document has one. Otherwise this is {!Safe_ops.parse_json_safe}: it trims,
    reads an empty body as an empty object, repairs UTF-8, and passes the
    decoder's own message through on a parse failure. *)

val bool_field : string -> t -> bool option
(** [None] when the field is absent or is not a boolean. *)

val string_field : string -> t -> string option
(** [None] when the field is absent or is not a string. *)

val int_field : string -> t -> int option
(** [None] when the field is absent or is not an integer. *)

val object_field : string -> t -> t option
(** [None] when the field is absent or is not an object. *)

val to_yojson : t -> Yojson.Safe.t
(** The parsed value. This is a projection of something {!parse} has already
    accepted, not a way around it: no document reaches here with a repeated
    key. Callers that hand a whole response body onward need it. *)
