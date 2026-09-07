(** Shell_ir — subset AST produced by the Menhir bash grammar (A1).

    The arm set is closed.  Anything outside the subset (heredoc, [$()]
    expansion, subshell, control flow, logic operators, function def,
    glob/brace expansion, backgrounding) is rejected at parse time as
    [Parsed.Too_complex _]. *)

type arg_meta = {
  quoted : bool;
  glob : bool;
  escaped : bool;
}

val default_meta : arg_meta

type arg =
  | Lit of string * arg_meta      (** single- or double-quoted literal *)
  | Concat of arg list            (** adjacent arg pieces: [foo"bar"$X] *)
  | Var of string * arg_meta      (** [$HOME], [${VAR}], [${VAR:-default}] *)

type simple = {
  bin : Exec_program.t;
  args : arg list;
  env : (string * arg) list;      (** [FOO=bar] env prefix on the command *)
  cwd : Path_scope.t option;
  redirects : Redirect_scope.t list;
  sandbox : Sandbox_target.t;
  (** Dispatch target — defaults to [Sandbox_target.host ()].  Keeper
      callers override with a guest or SSH runner closure over the
      keeper-side runtime (Docker via [Keeper_turn_sandbox_runtime]). *)
}

(** How the next command depends on the one before it. *)
type connector =
  | And_if  (** run the next command only if the one before it exited zero *)
  | Or_if  (** run the next command only if the one before it did not *)
  | Seq  (** run the next command regardless of exit status (semicolon ;) *)

type t =
  | Simple of simple
  | Pipeline of t list            (** length >= 2 — head | middle* | tail *)
  | Sequence of {
      head : t;
      tail : (connector * t) list;
    }
      (** [a && b || c] as [head = a], [tail = [And_if, b; Or_if, c]]. The
          first command is a separate field, so an empty sequence cannot be
          written down. Evaluation is left to right: each connector looks only
          at the status of whatever ran last. *)

val with_sandbox : Sandbox_target.t -> t -> t
(** [with_sandbox target ir] rebuilds [ir] with every stage's dispatch
    target set to [target], recursively. A [Delegated] stage keeps its own:
    it names a masc tool call whose routing is the delegation's. Execution
    reads the target from the IR ({!Exec_dispatch.dispatch} takes none), so
    a caller re-running a command under a different target must pass a
    rewritten IR — the observation stage (RFC-0422) does exactly this. *)

val pp : Format.formatter -> t -> unit
