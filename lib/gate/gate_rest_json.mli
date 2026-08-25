(** Reading a connector REST response under one duplicate-key policy.

    The two connectors used to disagree. [discord_rest_client] rejected a
    repeated object key on every field read; [slack_rest_client] took the first
    value through [List.assoc_opt]. JSON does not forbid a repeated key and
    Yojson does not reject one, so the same body could produce two different
    answers depending on which connector read it.

    A repeated key is a property of the document, not of one field read, so
    {!parse} settles it once. Every reader below is total on the result, and no
    call site is left holding an error it has to decide about. That last part
    is what actually leaked before: the rejecting reader returned
    [(_, string) result] per field, and two of its four call sites wrote
    [Ok _ | Error _ -> status], folding the rejection back into the default it
    was meant to prevent. *)

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
