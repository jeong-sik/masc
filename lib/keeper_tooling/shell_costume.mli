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
