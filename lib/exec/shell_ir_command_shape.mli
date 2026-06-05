(** Pure command-shape helpers for {!Shell_ir}.

    This module has no keeper, cwd, filesystem, or sandbox policy.  It only
    answers questions that can be derived from the parsed Shell IR. *)

type stage =
  { bin : string
  ; args : string list
  }

val normalize_command_name : string -> string
(** Normalize a command token to the lowercase basename used for shape checks. *)

val parsed_stages : Shell_ir.t -> stage list
(** Literal command stages from an IR. Returns [[]] when any stage contains
    non-literal argv fragments. *)

val effective_stages : Shell_ir.t -> stage list
(** Literal stages after simple wrapper unwrapping such as [env git ...] and
    [opam exec -- git ...]. *)

val is_git_diagnostic_command : Shell_ir.t -> bool
(** [true] for single-stage read/diagnostic git commands such as [git status],
    [git log], and [git worktree]. *)

val is_git_recovery_command : Shell_ir.t -> bool
(** [true] for narrow local git recovery forms:
    [git checkout HEAD -- <relative-path>...], [git reset --hard HEAD], and
    [git clean -df]. This does not lower risk; it is only command-shape data for
    callers with separate cwd/sandbox policy. *)
