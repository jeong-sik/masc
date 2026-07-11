(** Typed argv schema for Execute.

    Introduced by RFC-0091 PR-1 (§5.1.1) to replace raw
    command-string parsing with a structured executable/argv boundary.

    {2 Design constraints}

    - **No shell-string parsing**.  Validation is structural only:
      argv/cwd/env/redirect shape is checked here, while executable
      admission is left to Shell IR risk classification and the runtime
      write/destructive gates.
    - **Execve-style argv semantics**.  Each token in [argv] is passed
      verbatim to the child process; the implementation invokes the
      executable directly (no [/bin/sh -c "..."] wrapping).  Therefore
      shell metacharacters like [*], [?], [|], [&], [;], [>], [<],
      [`], [$], [\n], and [\r] inside a payload argv token are *literal
      characters*, not shell operators.  For example, the typed schema accepts
      [find . -name *.ml] because [*.ml] is a [find]-internal pattern, not a
      shell glob; it also accepts multiline `gh --body` text because the
      argument is passed directly to [gh].
    - **Pipelines are explicit**.  The top-level JSON [pipeline] field
      enumerates each [exec_stage] separately; [|]-delimited strings are never
      parsed.  A
      standalone pipe operator token (["|"] / ["|&"]) in direct [Exec.argv] is
      rejected because it can only become bogus argv data (for example
      [tail: |: No such file or directory]); use [pipeline] instead.
    - **Forbidden argv shapes**: [NUL], standalone pipe operator tokens, and
      shell redirection operator tokens.  [NUL] cannot be represented in an
      execve argv string.  Pipe/redirection operator tokens are rejected as
      command-shape mistakes while payload tokens that merely contain those
      characters remain allowed.
    - **Cwd is a string for now**.  Path SSOT does not yet expose a
      [Path.t] type (RFC-0091 §2.3 mis-cited [Host_config.cwd_for_keeper]
      which does not exist).  Absolute-path enforcement happens in
      {!validate}.  PR-3 may revisit when a path SSOT module lands. *)

type exec_stage = {
  executable : string;
  argv : string list;
}

type redirect_target =
  | Inherit
      (** default; child inherits the parent's file descriptor *)
  | Discard
      (** discard output / read empty input — equivalent to [/dev/null] *)
  | File of string
      (** absolute filesystem path.  stdout/stderr open for writing,
          stdin opens for reading.  RFC-0198 Phase B: the typed
          alternative to shell redirection syntax (which is rejected
          by Phase A's recognizer in [check_argv]). *)

type execute_input =
  | Exec of {
      executable : string;
      argv : string list;
      cwd : string option;
      env : (string * string) list;
      stdin : redirect_target;
      stdout : redirect_target;
      stderr : redirect_target;
    }
      (** [stdin], [stdout], [stderr] default to {!Inherit} when absent
          from JSON.  RFC-0198 Phase B introduced them so the LLM can
          express "discard stderr" or "write stdout to an absolute path"
          via typed schema, instead of attempting shell redirection
          syntax inside an execve-style argv (which silently leaks as
          a runtime [find: 2>/dev/null: unknown primary] failure). *)
  | Pipeline of {
      stages : exec_stage list;
      cwd : string option;
      env : (string * string) list;
    }
      (** Per-stage redirects are intentionally not exposed here — pipe
          construction owns the inter-stage fd plumbing.  Out-of-stage
          redirects on the pipeline's endpoints are a deferred extension. *)

type validation_error =
  | Empty_executable of { argv : string list }
  | Executable_repeated_in_argv0 of {
      executable : string;
      argv : string list;
    }
  | Argv_contains_shell_metachar of {
      executable : string;
      index : int;
      token : string;
    }
  | Argv_contains_shell_pipeline_operator of {
      executable : string;
      index : int;
      token : string;
    }
      (** Standalone shell pipeline operator token (["|"] or ["|&"]) in
          [Exec.argv].  These tokens are never interpreted as pipelines by
          execve and commonly become bogus filenames/arguments.  Use the
          top-level JSON [pipeline] field; payload tokens containing pipe
          characters (for example ["foo|bar"] or multiline markdown bodies)
          remain valid. *)
  | Argv_contains_shell_redirection of {
      executable : string;
      index : int;
      token : string;
    }
      (** RFC-0198 Phase A.  Token shape matches a shell redirection
          operator ([>], [>>], [2>], [2>>], [<], [0<], [2>&1], [>/path],
          [&1]).  These are shell-syntax constructs that have no meaning
          inside execve argv — the typed schema rejects them so the
          caller (LLM) receives a typed alternative pointing at
          {!RFC-0198 Phase B} typed redirect fields or {!Pipeline} mode,
          instead of the runtime [find]/[grep] "unknown primary" failure
          that previously surfaced via [exec exit 1]. *)
  | Redirect_path_not_absolute of {
      fd : int;
      path : string;
    }
      (** RFC-0198 Phase B.  A {!File} redirect target must be an
          absolute filesystem path; relative paths are rejected to
          mirror {!Cwd_not_absolute} semantics. *)
  | Cwd_not_absolute of string
  | Pipeline_empty
  | Pipeline_too_short
  | Env_key_invalid of string
  | Env_key_duplicate of string

val of_json : Yojson.Safe.t -> (execute_input, string) result
(** Parse the typed Execute JSON boundary.  Accepts either
    [{executable, argv?, cwd?, env?, timeout_sec?}] for [Exec] or
    [{pipeline = [{executable, argv?}, ...], cwd?, env?}] for [Pipeline].
    [timeout_sec] is accepted at this layer and consumed by the caller.
    [executable] and [pipeline] together, raw command-string fields, [{stages =
    ...}], and other unsupported fields are intentionally rejected here.  No
    compatibility normalization is applied at parse time: missing [find .]
    paths, empty [executable] fields, and duplicated executable tokens in
    [argv] remain caller-authored input for validation/lowering. *)

val validate : execute_input -> (unit, validation_error) result
(** Run all structural checks against [input].  Returns [Ok ()] on
    success, or the first {!validation_error} encountered.  Validation
    mirrors lowering's bounded argv0 autocorrection: a leading executable
    duplicate with at least one following argument is tolerated, while the
    caller-authored input is not mutated.  No side effects, no exceptions. *)

val to_shell_ir_unvalidated :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  execute_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Lower [input] into {!Masc_exec.Shell_ir.t} without structural validation.
    Callers that use the Shell IR facade ([Shell_command_gate.gate_typed])
    may use this entrypoint when the boundary has already been checked.
    Lowering drops a leading duplicated executable token only when at least
    one real argument remains after it; a single argument equal to the
    executable is preserved as caller-authored data. *)

val to_shell_ir :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  execute_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Validate and lower [input] into {!Masc_exec.Shell_ir.t}.  [Pipeline]
    inputs become an explicit {!Masc_exec.Shell_ir.Pipeline}; embedded pipe
    characters inside payload argv tokens remain ordinary argument data, while
    standalone pipe operator argv tokens are rejected before lowering.  [Exec]
    and pipeline-stage argv are lowered with the same bounded argv0
    autocorrection as {!to_shell_ir_unvalidated}.  [sandbox] defaults to host
    execution; keeper callers may provide Docker runtime targets after
    sandbox/profile resolution. *)

val pp_validation_error : Format.formatter -> validation_error -> unit
(** Human-readable formatter for {!validation_error}.  Stable across
    PR-1/PR-2 — callers may rely on the message structure for log
    classification.  ERROR text intentionally lacks the retired
    path-tokenizer prefix so the 4-layer log amplification is severed
    at PR-2 lexer deletion. *)

val validation_error_alternatives : validation_error -> string list
(** Structured alternatives for machine consumers (JSON responses).
    Returns field names the LLM should use instead of the rejected pattern.
    Empty list when no typed alternative exists.
    SSOT: each variant maps to exactly one alternatives list here;
    callers must not add ad-hoc alternatives at the JSON layer. *)
