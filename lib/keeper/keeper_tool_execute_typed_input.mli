(** Typed process-vector schema for Execute.

    Introduced by RFC-0091 PR-1 (§5.1.1) to replace raw
    command-string parsing with a structured non-empty argv boundary.

    {2 Design constraints}

    - **No shell-string parsing**.  Validation is structural only:
      argv/cwd/redirect shape is checked here, while external-effect
      authorization is handled by the product-neutral Gate.
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
    - **Pipelines are explicit**.  The top-level JSON [pipeline] field
      enumerates each [exec_stage] separately; no argv token is parsed or
      rewritten as shell syntax.
    - **Literal argv**.  [NUL] is the only rejected argument content because it
      cannot be represented at the process boundary.  Standalone [|], [|&],
      redirection-looking tokens, wildcard characters, and repeated argument
      tokens remain caller-authored literal argv.
    - **Cwd is a string for now**.  Path SSOT does not yet expose a
      [Path.t] type (RFC-0091 §2.3 mis-cited [Host_config.cwd_for_keeper]
      which does not exist).  Absolute-path enforcement happens in
      {!validate}.  PR-3 may revisit when a path SSOT module lands. *)

type input_source =
  | Inherit_input  (** default; the child keeps the parent's stdin *)
  | Empty_input  (** read nothing — [/dev/null] *)
  | Read_file of { path : string }  (** absolute path opened for reading *)
  | Literal_input of { bytes : string }
      (** the bytes themselves, with no file anywhere.

          This is what a heredoc is, and until it existed the tool could tell a
          caller its heredoc belonged in the stdin field while the stdin field
          had nowhere to put it. Content never reaches the filesystem, so
          nothing has to be cleaned up and nothing else can read it on the way
          past. *)
      (** stdin cannot duplicate another descriptor: a merge is carried out on
          captured output and stdin is not a capture. *)

type output_sink =
  | Inherit_output  (** default; the child keeps the parent's descriptor *)
  | Discard_output  (** throw the bytes away — [/dev/null] *)
  | Truncate_file of { path : string }  (** absolute path, shell [>] *)
  | Append_file of { path : string }  (** absolute path, shell [>>] *)
  | Output_to_fd of int
      (** duplicate another standard descriptor of the same stage, which is
          how [2>&1] is expressed without a shell. The dispatcher captures the
          two streams separately and joins them afterwards, so the merged text
          is grouped by stream rather than ordered by time. *)

type exec_stage = {
  argv : string list;
  stdin : input_source;
  stdout : output_sink;
  stderr : output_sink;
}
(** One process and where its three standard streams attach. Every stage owns
    its own redirections, including stages inside a pipeline. *)

type program = {
  head : exec_stage;
  tail : exec_stage list;
}
(** One or more stages joined by pipes. The head/tail split makes the empty
    program unrepresentable, so emptiness is not something {!validate} has to
    check, and a single process is a program whose tail is empty. *)

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
  | Staged of { program : program }
      (** one process or pipeline, typed, reaching no shell. Running one
          command after another is a shell's job, so it is written as a
          [script]. *)
  | Script of script
      (** one command line, run by a real shell inside the keeper's sandbox.

          RFC execute-boundary-is-the-sandbox: the field the caller chose names
          the execution model. [argv] and [pipeline] are typed and reach no
          shell; [script] is a shell. The bash subset still parses this text,
          but as a judge — for path classification, telemetry, and the rewrite
          advice that rides back — rather than as the thing that runs. *)
(** Where the work comes from. The schema says [argv], [pipeline] and [script]
    exclude each other; saying it here too makes "both" and "neither"
    unrepresentable rather than something {!validate} has to catch. *)

type execute_input = {
  source : source;
  cwd : string option;
  timeout_sec : float option;
}
(** [cwd] applies to every stage of the program. [timeout_sec] is an explicit
    optional execution boundary; absence means unbounded execution. *)

type validation_error =
  | Empty_argv
  | Empty_program
  | Redirect_outside_the_sandbox_mount of {
      path : string;
      visible_root : string;
    }
      (** A sandboxed command's redirect target has to sit inside the mount
          that the sandbox and this host share; outside it, the same path
          names two different files and only one of them is reachable here. *)
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
  | Redirect_path_not_absolute of {
      fd : int;
      path : string;
    }
      (** A {!File} redirect target must be an absolute filesystem path;
          relative paths are rejected to
          mirror {!Cwd_not_absolute} semantics. *)
  | Cwd_not_absolute of string
  | Redirect_fd_unknown of {
      fd : int;
      target : int;
    }
      (** A {!Fd} redirect may only duplicate a descriptor the stage owns:
          0, 1 or 2. *)

val of_json : Yojson.Safe.t -> (execute_input, string) result
(** Parse the typed Execute JSON boundary into a {!program}.

    [{argv, stdin?, stdout?, stderr?}] at the top level is a one-stage
    program; [{pipeline = [stage, ...]}] is an n-stage one. A stage carries
    its own redirections in both forms, so piping and redirecting are not
    alternatives.

    [argv] and [pipeline] together, raw command-string fields and other
    unsupported fields are rejected here. No compatibility normalization is
    applied at parse time. *)

val validate : execute_input -> (unit, validation_error) result
(** Run all structural checks against [input].  Returns [Ok ()] on
    success, or the first {!validation_error} encountered.  No argv token is
    inferred, rejected as shell syntax, or rewritten.  No side effects, no
    exceptions. *)

(** Which filesystem a redirect target names. A keeper running in a container
    writes paths as the container sees them; [Bound_mount] carries the two
    roots that make one of those a path on this host, which holds only inside
    the shared mount. Without it the target stays in the command's namespace
    and a sandboxed dispatch refuses it rather than opening whatever this host
    has at that path. *)
type redirect_namespace =
  | Command_filesystem
  | Bound_mount of {
      visible_root : string;
      host_root : string;
    }

val to_shell_ir_unvalidated :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  ?namespace:redirect_namespace ->
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
    apply to [script:S] -- path scope, redirect policy, the absence of [;] from
    {!Masc_exec.Shell_ir.connector} -- stop applying inside it.  Each pair is
    the shell name and a closed-vocabulary tag from
    {!Keeper_tooling.Shell_costume.finding_tag}.

    Recognition and classification only: calling this changes nothing about
    what runs.  [Script] sources yield [[]] -- they already crossed the gate.
    RFC execute-subset-dispositions step 1: this distribution is what decides
    which constructs the subset rewrites first. *)

val to_shell_ir :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  ?namespace:redirect_namespace ->
  execute_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Validate and lower [input] into {!Masc_exec.Shell_ir.t}.  [Pipeline]
    inputs become an explicit {!Masc_exec.Shell_ir.Pipeline}; embedded pipe
    characters and standalone shell-looking tokens inside argv remain ordinary
    argument data.  [sandbox] defaults to host execution; keeper callers may
    provide Docker runtime targets after sandbox/profile resolution. *)

val pp_validation_error : Format.formatter -> validation_error -> unit
(** Human-readable formatter for {!validation_error}.  Stable across
    PR-1/PR-2 — callers may rely on the message structure for log
    classification.  ERROR text intentionally lacks the retired
    path-tokenizer prefix so the 4-layer log amplification is severed
    at PR-2 lexer deletion. *)
