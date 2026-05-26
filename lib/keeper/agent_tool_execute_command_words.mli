(** Low-level raw shell command word extraction.

    This module owns dependency-light string -> Shell IR -> word extraction
    helpers used by keeper subsystems that need command-shape evidence but
    must not depend on the heavier keeper shell semantics layer. *)

type guard_token =
  | Guard_word of string * bool
  | Guard_separator

val first_token_of_cmd : string -> string option
(** First flattened command token from a raw shell command. Returns [None] on
    parse failure or empty commands. *)

val cmd_prefix : string -> string
(** First command token for history/action summaries. Uses parsed Shell IR words
    when possible and falls back to a conservative leading-token extraction for
    unsupported shell shapes. *)

val guard_tokens_of_cmd : string -> guard_token list
(** Parse a raw shell command into lowercased guard tokens plus top-level command
    separators. Quoted words preserve a [true] quoted flag; unquoted [;], [&&],
    and [||] become [Guard_separator]. Returns [[]] on parse failure. *)
