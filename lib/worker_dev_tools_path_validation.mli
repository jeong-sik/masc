(** Path-token validation helpers for worker dev tools. *)

type path_token = Worker_dev_tools_path_words.t

val looks_like_url : string -> bool
val is_path_flag : string -> bool
val path_flag_requires_existing_dir : string -> bool
val path_value_of_flagged_token : string -> string option
val inline_path_flag_requires_existing_dir : string -> bool
val command_materializes_path_arg : string -> bool
val path_is_existing_dir : ?workdir:string -> string -> bool
val looks_like_path_token : string -> bool
val token_value_is_explicit_path : string -> bool
val token_has_parent_dir_segment : string -> bool
val git_revisionish_token : ?workdir:string -> string -> bool
val token_has_unsafe_rewrite_syntax : path_token -> bool
val command_allows_safe_globbed_path : string -> bool
val token_glob_is_limited_to_basename : path_token -> bool
val path_token_error_hint : path_token -> string
val path_syntax_blocked_message : path_token -> string
val token_value_is_redirect_to_dev_null : path_token -> bool
val token_value_is_redirect_op : path_token -> bool
val command_pattern_arg_flags : string -> (string * bool) list
val token_is_inline_pattern_flag : string -> path_token -> bool option
val command_flag_pattern_arity : string -> string -> bool option
val rg_token_is_option_value : path_token -> bool
val command_treats_plain_args_as_content : string -> bool
val path_argument_tokens : path_token list -> path_token list
val existing_dir_path_values : string -> string list

val validate_command_paths
  :  ?keeper_id:string
  -> ?base_path:string
  -> ?workdir:string
  -> string
  -> (unit, string) result
