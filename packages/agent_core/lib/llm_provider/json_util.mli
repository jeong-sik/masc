(** Shared JSON helpers for the llm_provider library. *)

(** Maximum allowed JSON container nesting depth ({[ { ]} and {[ [ ]}) for
    untrusted provider payloads before {!Yojson.Safe.from_string} runs. *)
val max_json_nesting_depth : int

(** Fast O(N) iterative scanner verifying that JSON container nesting depth
    does not exceed [max_depth] (default {!max_json_nesting_depth}). Prevents
    untrusted deeply-nested payloads from triggering OCaml [Stack_overflow]
    inside recursive Yojson parsing. *)
val check_nesting_depth : ?max_depth:int -> string -> (unit, string) result

(** Parse untrusted JSON with an O(N) nesting-depth pre-check and defensive
    [Stack_overflow] containment, returning [Error detail] instead of crashing
    the fiber/switch. *)
val from_string_bounded : ?max_depth:int -> string -> (Yojson.Safe.t, string) result

(** Like {!from_string_bounded}, raising [Yojson.Json_error detail] on depth
    or syntax errors so existing [Yojson.Json_error] handlers contain deep
    nesting cleanly without leaking [Stack_overflow]. *)
val from_string_bounded_exn : ?max_depth:int -> string -> Yojson.Safe.t

(** Clamp a parsed token count to non-negative ([>= 0]). *)
val clamp_non_negative : int -> int

(** Saturating non-negative integer addition for token counters: clamps each
    operand to [>= 0] and saturates at [Int.max_int] instead of wrapping
    negative on signed 63-bit overflow. *)
val saturating_add_non_negative : int -> int -> int

(** The value of field [name] when the JSON value is an object that has one, [None] for a
    missing field and for every other kind of value. With a repeated key the first
    occurrence wins. *)
val assoc_member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option

(** Return a human-readable JSON type name.

    Uses JSON-schema vocabulary: [object], [array], [string], [number],
    [boolean], [null]. *)
val json_type_name : Yojson.Safe.t -> string

(** Run [decoder] over a raw provider payload.

    Contains every exception Yojson raises at this boundary —
    [Yojson.Json_error] on malformed syntax or excessive nesting depth,
    [Yojson.Safe.Util.Type_error] and [Yojson.Safe.Util.Undefined] on shape
    mismatch (e.g. [Util.member] applied to a 2xx body that is [null], an
    array, or a scalar) — and returns them as [Error message]. Provider
    response parsers must decode through this function instead of catching
    [Yojson.Json_error] alone, which lets shape exceptions escape the [result]
    contract. *)
val decode_json_with : (Yojson.Safe.t -> 'a) -> string -> ('a, string) result
