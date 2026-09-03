(** Typed process-vector schema for Execute.

    Introduced by RFC-0091 PR-1 (§5.1.1) to replace raw
    command-string parsing with a structured non-empty argv boundary.

    {2 Design constraints}

    - **No shell-string parsing**.  Validation is structural only:
      argv/cwd shape is checked here, while external-effect authorization is
      handled by the product-neutral Gate.
    - **Single command SSOT**.  [argv] is a non-empty process vector whose
      first token is the executable and whose remaining tokens are its
      arguments.  There is no second [executable] field that can disagree
      with, or be accidentally repeated in, [argv].
    - **Execve-style argv semantics**.  Each argument token is passed verbatim
      to the child process; the implementation invokes [argv[0]] directly (no
      [/bin/sh -c "..."] wrapping).  Therefore
      shell metacharacters like [*], [?], [|], [&], [;], [>], [<],
      [`], [$], [\n], and [\r] inside a payload argv token are *literal
      characters*, not shell operators.  For example, the typed schema accepts
      a program-internal wildcard pattern because the token is passed directly
      to that program rather than expanded by a shell.
    - **Pipes are shell syntax**.  A pipeline is a line, so it is written as
      a [script]; no argv token is parsed or rewritten as shell syntax.
    - **Literal argv**.  [NUL] is the only rejected argument content because it
      cannot be represented at the process boundary.  Standalone [|], [|&],
      redirection-looking tokens, wildcard characters, and repeated argument
      tokens remain caller-authored literal argv.
    - **Cwd is a string for now**.  Path SSOT does not yet expose a
      [Path.t] type (RFC-0091 §2.3 mis-cited [Host_config.cwd_for_keeper]
      which does not exist).  Absolute-path enforcement happens in
      {!validate}.  PR-3 may revisit when a path SSOT module lands. *)

type script = {
  shell : string;
      (** the shell that runs [text], as one of the names
          {!Keeper_tooling.Shell_costume.names_a_shell} recognises, with any
          directory stripped. *)
  text : string;  (** handed to that shell after [-c] *)
}
(** A command line and the shell that runs it.

    The shell is carried rather than fixed because
    [argv:\["bash";"-c";S\]] normalises to this form and must keep the shell it
    named. Resolving a bash expansion under a container's [sh] is dash, and
    the corpus has 656 of them. *)

type source =
  | Argv of string list
      (** one process, typed, reaching no shell. Piping, redirecting and
          running one command after another are a shell's job, so they are
          written as a [script]. *)
  | Script of script
      (** one command line, run by a real shell inside the keeper's sandbox.

          RFC execute-boundary-is-the-sandbox: the field the caller chose names
          the execution model. [argv] is typed and reaches no shell; [script]
          is a shell. The bash subset still parses this text,
          but as a judge — for path classification, telemetry, and the rewrite
          advice that rides back — rather than as the thing that runs. *)
(** Where the work comes from. The schema says [argv] and [script] exclude
    each other; saying it here too makes "both" and "neither" unrepresentable
    rather than something {!validate} has to catch. *)

type execute_input = {
  source : source;
  cwd : string option;
  timeout_sec : float option;
}
(** [cwd] applies to the command. [timeout_sec] is an explicit
    optional execution boundary; absence means unbounded execution. *)

type validation_error =
  | Empty_argv
  | Empty_program
  | Directory_change_is_not_a_program of { requested : string }
      (** [cd] changes the shell's own directory. Run as a program it changes
          the directory of a child that exits immediately, so the command the
          caller meant never runs — and [cd] ignores its extra arguments and
          exits zero, so the call is reported successful with no output. Use
          the [cwd] field. *)
  | Argv_contains_nul of {
      index : int;
      token : string;
    }
  | Cwd_not_absolute of string

val of_json : Yojson.Safe.t -> (execute_input, string) result
(** Parse the typed Execute JSON boundary.

    [{argv}] is one process; [{script, shell?}] is one command line for a
    shell. Both together, raw command-string fields and other unsupported
    fields are rejected here. No compatibility normalization is applied at
    parse time. *)

val validate : execute_input -> (unit, validation_error) result
(** Run all structural checks against [input].  Returns [Ok ()] on
    success, or the first {!validation_error} encountered.  No argv token is
    inferred, rejected as shell syntax, or rewritten.  No side effects, no
    exceptions. *)

val to_shell_ir_unvalidated :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  execute_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Lower [input] into {!Masc_exec.Shell_ir.t} without structural validation.
    Callers that use the Shell IR facade ([Shell_command_gate.gate_typed])
    may use this entrypoint when the boundary has already been checked.  Argv
    is preserved byte-for-byte. *)

val hidden_script_findings
  :  sandbox:Masc_exec.Sandbox_target.t
  -> execute_input
  -> (string * Keeper_tooling.Shell_costume.finding) list
(** The scripts hidden inside argv, and what the gate would have called each.

    The finding rather than its tag: a caller that wants to hand the writer a
    rewrite needs the typed reason, and the tag is one rendering of it. Losing
    the reason here would mean the only thing left to say is the name of the
    problem.

    [argv:["sh";"-c";S]] arrives as one opaque program with two literal
    arguments, so S is counted as nothing at all while the guarantees that
    apply to [script:S] -- path scope, gate policy -- stop applying inside it.
    Each pair is
    the shell name and a closed-vocabulary tag from
    {!Keeper_tooling.Shell_costume.finding_tag}.

    Recognition and classification only: calling this changes nothing about
    what runs.  RFC execute-subset-dispositions step 1: this distribution is what decides
    which constructs the subset rewrites first. *)

val to_shell_ir :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  execute_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Validate and lower [input] into {!Masc_exec.Shell_ir.t}.  Embedded pipe
    characters and standalone shell-looking tokens inside argv remain ordinary
    argument data.  [sandbox] defaults to host execution; keeper callers may
    provide Docker runtime targets after sandbox/profile resolution. *)

val pp_validation_error : Format.formatter -> validation_error -> unit
(** Human-readable formatter for {!validation_error}.  Stable across
    PR-1/PR-2 — callers may rely on the message structure for log
    classification.  ERROR text intentionally lacks the retired
    path-tokenizer prefix so the 4-layer log amplification is severed
    at PR-2 lexer deletion. *)
