(** Path_scope — abstract classification of argv path arguments.

    RFC v5 A0: every path that appears in a [Shell_ir.Simple] (cwd,
    redirect target, or positional argument syntactically resembling a
    path) is classified at parse time into one of four scopes.  Policy
    decisions consume the scope, never the raw string. *)

type t

type scope =
  | Inside_worktree of string (** path beneath the current workspace root *)
  | Inside_sandbox of string (** [.masc/], [/tmp/masc-*] and similar *)
  | Outside_worktree of string (** path escapes the workspace root *)
  | Absolute_unknown of string (** absolute path we cannot place *)

(** Classify [raw] relative to [cwd].  Arm selection is deterministic
    and fail-closed: a path that cannot be resolved lands in
    [Absolute_unknown] rather than being silently admitted. *)
val classify : raw:string -> cwd:string -> t

val scope : t -> scope
val raw : t -> string
val pp : Format.formatter -> t -> unit
