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

val first_command_name : Shell_ir.t -> string option
(** First command name in an IR, ignoring argv literals. *)

val last_command_name : Shell_ir.t -> string option
(** Last command name in an IR, ignoring argv literals. For pipelines this is
    the exit-code-determining stage. *)

val top_level_stage_count : Shell_ir.t -> int
(** Number of top-level stages. A simple command counts as one. *)
