(** Autonomy_diff_guard — pure unified-diff validation helper.

    @since 0.92.1 *)

type issue =
  | Empty_patch
  | Unsafe_path of string
  | Outside_allowed_paths of string
  | Banned_addition of
      { path : string option
      ; pattern : string
      ; line : string
      }

type report =
  { accepted : bool
  ; touched_paths : string list
  ; issues : issue list
  }

val default_banned_patterns : string list

val normalize_command : string -> string

val show_issue : issue -> string

type allowed_spec =
  | Exact of string
  | Prefix of string

val normalize_path : string -> (string, issue) result

val normalize_allowed_path : string -> (allowed_spec, issue) result

val path_allowed : allowed_spec list -> string -> bool

val parse_path_token : string -> int -> string

val parse_diff_git_path : string -> (string, issue) result

val add_unique : 'a list -> 'a -> 'a list

val validate_patch :
  allowed_paths:string list -> ?banned_patterns:string list -> string -> report
