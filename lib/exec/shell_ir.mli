(** Shell_ir — subset AST produced by the Menhir bash grammar (A1).

    The arm set is closed.  What the lexer refuses is rejected at parse time
    as [Parsed.Too_complex _], and bash_lexer.mll is the list: [$] in any
    form (parameter, [$(...)], [$((...))], backticks), here-strings, a
    heredoc whose tag is unquoted, process substitution, the redirect forms
    the grammar does not spell ([&>], [>|], [<>], [>&-]), backgrounding,
    subshell parentheses, and braces.

    Three things this sentence used to name are inside the subset. [&&],
    [||] and [;] are connectors the IR holds. A heredoc with a quoted tag
    ([<<'TAG'], [<<"TAG"]) is read, because a quoted tag means the body is
    literal and needs no expansion pass. An unquoted [*] is not refused at
    all — it survives as a literal argv token, so the same text means one
    thing through a shell and another through here.

    Control flow and a function definition have no rule of their own: [for],
    [while] and [if] lex as words, and a function definition is refused only
    because it reaches a [(].  So a loop is reported by whatever excluded
    lexeme it happens to contain, which is a tag that names a construct and
    not the loop.

    test/test_shell_costume.ml holds this as a measured table. *)

type arg_meta = {
  quoted : bool;
  glob : bool;
  escaped : bool;
}

val default_meta : arg_meta

type arg =
  | Lit of string * arg_meta      (** single- or double-quoted literal *)
  | Concat of arg list            (** adjacent arg pieces: [foo"bar"$X] *)
  | Var of string * arg_meta
      (** Unresolved variable syntax. Parsing and execution refuse it until
          an execution-target environment can own its interpretation. *)

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

val has_variable_expansion : t -> bool
(** Includes argument concatenations, environment prefixes and every stage.
    A variable has no execution-target environment authority in this IR. *)

val pp : Format.formatter -> t -> unit
