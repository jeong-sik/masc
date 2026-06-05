(** Command-token helpers shared by keeper execution guards. *)

type guard_token =
  | Guard_word of string * bool
  | Guard_separator

val first_token_of_cmd : string -> string option
val strip_simple_shell_quotes : string -> string
val cmd_prefix : string -> string
val guard_tokens_of_cmd : string -> guard_token list
