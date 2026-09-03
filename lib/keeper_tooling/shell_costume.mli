(** A shell wearing an argv costume.

    [argv:["sh";"-c";"cd x && build"]] and [script:"cd x && build"] are the same
    text, but only the second crosses the gate: the first lowers to one opaque
    program with two literal arguments, so path scope, redirect policy, and the
    absence of [;] from {!Masc_exec.Shell_ir.connector} all stop applying inside
    those quotes.

    This module recognises the costume and says what the gate would have made of
    the text underneath.  It does not change what runs.  RFC
    execute-subset-dispositions step 1: the distribution of {!finding} over live
    traffic is what decides which constructs the subset resolves next, and a
    script hidden inside [argv] is currently counted as nothing at all. *)

type t = private {
  shell : string;  (** [argv\[0\]] with any directory stripped, e.g. ["sh"] *)
  script : string;  (** the argument after the [-c] flag *)
}

val shells : string list
(** The shells this module recognises, for a caller that has to name them in a
    message or an enum. {!names_a_shell} is the predicate over the same list;
    a second copy of it would drift. *)

val names_a_shell : string -> bool
(** Whether a program is one of the shells this module recognises.  The
    argument is the program as written, with or without a directory:
    ["/bin/zsh"] and ["zsh"] both answer true.

    Exposed so a reader asking "did this call end up lowered, or is it still a
    shell?" answers with the same list {!of_argv} recognises by. Two copies of
    that list drift, and the number the second one prints would then be about
    itself. The directory is stripped here for the same reason -- a caller that
    had to remember to strip it was the caller that did not. *)

val ir_keeps_a_shell : Masc_exec.Shell_ir.t -> bool
(** Whether any stage of [ir] still invokes a shell.

    The tap asks this of the dispatch result to report whether the costume came
    off. Every stage answers, because lowering rewrites one costume and leaves a
    sibling stage's [bash -c] where it was.

    That sibling no longer arrives from Execute -- since #32662 its input
    lowers to a single [Simple] -- so in production this reads one stage.
    The multi-stage arms answer for the rest of [Shell_ir.t] and are covered
    by this module's own tests. *)

val of_argv : string list -> t option
(** [Some t] when [argv] is a shell invoked with [-c] and a script argument.

    [None] covers three different things on purpose -- not a shell, a shell with
    no [-c] (an interactive or script-file invocation, which has no text to
    classify), and [-c] with nothing after it.  None of them carries a hidden
    script, so none of them is this module's concern. *)

type finding =
  | Representable
      (** the gate would have lowered this text to IR and run it under policy *)
  | Refused_by_policy of string
      (** parses inside the subset, refused by the gate's own policy *)
  | Outside_the_subset of
      Masc_exec_command_gate.Shell_command_gate.too_complex_reason
      (** parses as bash, outside what the IR can represent *)
  | Unparsable of Masc_exec_command_gate.Shell_command_gate.parse_reason

val classify
  :  syntax_policy:Masc_exec_command_gate.Shell_command_gate.syntax_policy
  -> sandbox:Masc_exec_command_gate.Shell_command_gate.sandbox_context
  -> t
  -> finding
(** Classify without logging and without running anything.  Uses
    {!Masc_exec_command_gate.Shell_command_gate.decide_raw} rather than
    [gate_raw] so a shadow classification does not emit a line that reads like a
    real raw dispatch. *)

val finding_tag : finding -> string
(** Stable snake_case tag for aggregation.  Closed vocabulary: a new
    {!finding} arm cannot be added without choosing its tag. *)
