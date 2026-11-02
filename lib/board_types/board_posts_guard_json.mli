(** Pure codec for the posts initialization guard. The caller owns JSONL
    framing: exactly one physical, LF-terminated row is required. *)

type t

type rejection =
  | Invalid_json of { line : int; detail : string }
  | Field_set_rejected
  | Schema_not_string
  | Unsupported_schema of string
  | Invalid_generation

val decode_row : line:int -> string -> (t, rejection) result
(** Decode one row without its terminating LF. Only the [schema] and
    [generation] fields are accepted, once each, in either order. *)

val of_generation : string -> (t, rejection) result
(** Accept exactly 32 lowercase ASCII hexadecimal characters, without
    trimming or coercion. This function does not generate an identifier. *)

val generation : t -> string
val encode_jsonl : t -> string
(** Encode the supported schema as one compact object followed by LF. *)
