(** Phonebook TOML parser — public interface. *)

type parse_error = { path : string; message : string }
[@@deriving show]

val parse_phonebook :
  Otoml.t -> (Cascade_phonebook_types.cascade_phonebook, parse_error list) result
(** Parse a phonebook TOML document into typed phonebook config. *)
