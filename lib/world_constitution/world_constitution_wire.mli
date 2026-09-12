(** JSON wire form for constitution ledger entries (RFC-0442).

    The schema is closed: an unknown or duplicated field is a rejection, not a
    field to ignore. A decoder that answers [None] tells its caller only that
    something is wrong, so every rejection names its path and reason. *)

type decode_step =
  | Field of string
  | Index of int

type decode_reason =
  | Expected_object
  | Expected_array
  | Expected_string
  | Expected_number
  | Missing_field of string
  | Unknown_field of string
  | Duplicate_field of string
  | Unknown_entry of string
  | Invalid_id of string
  | Invalid_article of World_constitution_types.invalid

type decode_error = {
  path : decode_step list;  (** Outermost step first. *)
  reason : decode_reason;
}

val decode_error_to_string : decode_error -> string
val entry_to_json : World_constitution_types.entry -> Yojson.Safe.t

val entry_of_json :
  Yojson.Safe.t -> (World_constitution_types.entry, decode_error) result
(** Decoding runs the same {!World_constitution_types.make} checks a fresh
    article passes, so a hand-edited ledger line cannot introduce an article
    the constructor would have refused. *)
