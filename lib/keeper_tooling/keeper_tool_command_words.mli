(** Low-level raw shell command word extraction for keeper policy surfaces.

    Command parsing is owned by [Exec_policy] and quote-aware tokenization by
    [Masc_exec_shell_words.Shell_words]. This module is the small keeper-facing
    adapter for call sites that need command-shape evidence without depending
    on tool execution runtime modules. *)

type guard_token =
  | Guard_word of string * bool
  | Guard_separator

type command_word_parse_error =
  | Shell_ir_parse_error of Exec_policy.block_reason
  | Shell_words_parse_error of
      { segment : string
      ; error : Masc_exec_shell_words.Shell_words.error
      }

type guard_tokens_with_errors =
  { guard_tokens : guard_token list
  ; guard_token_parse_errors : command_word_parse_error list
  }

val command_word_parse_error_to_string : command_word_parse_error -> string

val first_token_of_cmd_result :
  string -> (string option, command_word_parse_error) result
(** Result-returning variant of {!first_token_of_cmd}. Empty commands are
    [Ok None]; parser rejection is [Error]. *)

val first_token_of_cmd : string -> string option
(** First flattened command token from a raw shell command. Returns [None] on
    parse failure or empty commands; parse failures are logged by this legacy
    facade. *)

val cmd_prefix_result : string -> (string, command_word_parse_error) result
(** Result-returning variant of {!cmd_prefix}. Unsupported shell shapes surface
    the parser rejection instead of using the leading-token fallback. *)

val cmd_prefix : string -> string
(** First command token for history/action summaries. Uses parsed Shell IR words
    when possible and falls back to a conservative leading-token extraction for
    unsupported shell shapes; fallback parse failures are logged by this legacy
    facade. *)

val guard_tokens_of_cmd_with_errors : string -> guard_tokens_with_errors
(** Parse a raw shell command into guard tokens plus command-word parse
    diagnostics. Successfully parsed segments are retained even when another
    segment fails tokenization. *)

val guard_tokens_of_cmd : string -> guard_token list
(** Parse a raw shell command into lowercased guard tokens plus command
    separators. Quoted words preserve a [true] quoted flag. This legacy facade
    logs tokenizer failures and returns the successfully parsed tokens. *)
