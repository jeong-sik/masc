type shell_quote_state = No_quote | Single_quote | Double_quote

type shell_word = {
  text : string;
  starts_command : bool;
}

val shell_words_with_boundaries : string -> shell_word list
val command_name : string -> string
val shell_c_payload : shell_word list -> string option
val strip_command_wrappers : shell_word list -> shell_word list

val direct_tool_command_name :
  meta:Keeper_types.keeper_meta -> string -> (string * bool) option

val cmd_contains_gh_pr_create : string -> bool
