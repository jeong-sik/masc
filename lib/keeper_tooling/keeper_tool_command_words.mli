(** Low-level raw shell command word extraction for keeper policy surfaces.

    Command parsing is owned by [Exec_policy] and quote-aware tokenization by
    [Masc_exec_shell_words.Shell_words]. This module is the small keeper-facing
    adapter for call sites that need command-shape evidence without depending
    on tool execution runtime modules. *)

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
(** Parse a raw shell command into lowercased guard tokens plus command
    separators. Quoted words preserve a [true] quoted flag. Returns [[]] when
    the quote-aware tokenizer cannot recover words. *)
