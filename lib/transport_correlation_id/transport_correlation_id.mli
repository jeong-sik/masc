(** Opaque identifiers that correlate work within one transport connection.

    Generated identifiers use the repository's canonical UUIDv7 boundary.
    Observer-provided identifiers remain opaque visible ASCII, but invalid
    values are rejected instead of being silently replaced. *)

type error =
  | Missing
  | Invalid_visible_ascii

val is_valid : string -> bool
(** [is_valid value] accepts a non-empty sequence of visible ASCII bytes. *)

val generate : unit -> string
(** Generates a fresh canonical UUIDv7 correlation identifier. *)

val resolve : string option -> (string, error) result
(** Preserves a valid explicit observer identifier. Missing and invalid
    values are rejected so reconnects cannot silently switch identity. *)

val error_to_string : error -> string
