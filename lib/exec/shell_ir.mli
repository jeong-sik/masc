(** Shell_ir — subset AST produced by the Menhir bash grammar (A1).

    The arm set is closed.  Anything outside the subset (heredoc, [$()]
    expansion, subshell, control flow, logic operators, function def,
    glob/brace expansion, backgrounding) is rejected at parse time as
    [Parsed.Too_complex _]. *)

type arg =
  | Lit of string                 (** single- or double-quoted literal *)
  | Concat of arg list            (** adjacent arg pieces: [foo"bar"$X] *)
  | Var of string                 (** [$HOME], [${VAR}], [${VAR:-default}] *)

type simple = {
  bin : Bin.t;
  args : arg list;
  env : (string * arg) list;      (** [FOO=bar] env prefix on the command *)
  cwd : Path_scope.t option;
  redirects : Redirect_scope.t list;
}

type t =
  | Simple of simple
  | Pipeline of t list            (** length >= 2 — head | middle* | tail *)

val pp_arg : Format.formatter -> arg -> unit
val pp : Format.formatter -> t -> unit
