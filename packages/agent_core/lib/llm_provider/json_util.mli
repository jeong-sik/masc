(** Shared JSON helpers for the llm_provider library. *)

(** Return a human-readable JSON type name.

    Uses JSON-schema vocabulary: [object], [array], [string], [number],
    [boolean], [null]. *)
val json_type_name : Yojson.Safe.t -> string

(** Run [decoder] over a raw provider payload.

    Contains every exception Yojson raises at this boundary —
    [Yojson.Json_error] on malformed syntax, [Yojson.Safe.Util.Type_error]
    and [Yojson.Safe.Util.Undefined] on shape mismatch (e.g. [Util.member]
    applied to a 2xx body that is [null], an array, or a scalar) — and
    returns them as [Error message]. Provider response parsers must decode
    through this function instead of catching [Yojson.Json_error] alone,
    which lets shape exceptions escape the [result] contract. *)
val decode_json_with : (Yojson.Safe.t -> 'a) -> string -> ('a, string) result
