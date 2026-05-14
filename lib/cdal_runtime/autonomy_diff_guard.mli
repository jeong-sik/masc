(** Autonomy_diff_guard — pure unified-diff validation helper.

    This module does not apply or revert patches. It only validates whether
    a patch stays within explicit file boundaries and whether added lines
    contain banned patterns.

    @since 0.92.1

    @stability Evolving
    @since 0.93.1 *)

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
val show_issue : issue -> string

val validate_patch
  :  allowed_paths:string list
  -> ?banned_patterns:string list
  -> string
  -> report
