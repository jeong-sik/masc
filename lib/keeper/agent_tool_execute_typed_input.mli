(** Typed argv schema for Execute.

    Introduced by RFC-0091 PR-1 (§5.1.1) to replace raw
    command-string parsing with a structured executable/argv boundary.

    {2 Design constraints}

    - **No shell-string parsing**.  Validation is membership against
      {!Dev_exec_allowlist} plus structural checks on argv/cwd.
      Allowlisted wrapper executables ([env], [opam exec]) are resolved
      over explicit argv tokens and their effective target executable is
      checked against the same allowlist.
    - **Execve-style argv semantics**.  Each token in [argv] is passed
      verbatim to the child process; the implementation invokes the
      executable directly (no [/bin/sh -c "..."] wrapping).  Therefore
      shell metacharacters like [*], [?], [|], [&], [;], [>], [<],
      [`], [$] inside an argv token are *literal characters*, not
      shell operators.  For example, the typed schema accepts
      [find . -name *.ml] because [*.ml] is a [find]-internal pattern,
      not a shell glob.
    - **Pipelines are explicit**.  [Pipeline.stages] enumerates each
      [exec_stage] separately; [|]-delimited strings are never parsed.
    - **Forbidden in argv tokens**: only control characters that
      cannot survive process boundary serialization
      ([NUL], [\n], [\r]).  The validator rejects them via
      {!Argv_contains_shell_metachar} (name kept for log continuity;
      semantics narrowed in PR-1 follow-up commit).
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

type allowlist_mode =
  | Dev_full
  | Readonly

type validation_error =
  | Executable_not_allowlisted of {
      name : string;
      mode : allowlist_mode;
    }
  | Empty_executable of { argv : string list }
  | Empty_argv of { executable : string }
  | Argv_contains_shell_metachar of {
      executable : string;
      index : int;
      token : string;
    }
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

val of_json : Yojson.Safe.t -> (execute_input, string) result
(** Parse the typed Execute JSON boundary.  Accepts either
    [{executable, argv?, cwd?, env?, timeout_sec?}] for [Exec] or
    [{pipeline = [{executable, argv?}, ...], cwd?, env?}] for [Pipeline].
    [timeout_sec] is accepted at this layer and consumed by the caller.
    [executable] and [pipeline] together, raw command-string fields, [{stages =
    ...}], and other unsupported fields are intentionally rejected here.  No
    compatibility normalization is applied: missing [find .] paths, empty
    [executable] fields, and duplicated executable tokens in [argv] remain
    caller errors. *)

val validate : mode:allowlist_mode -> execute_input -> (unit, validation_error) result
(** Run all structural checks against [input].  Returns [Ok ()] on
    success, or the first {!validation_error} encountered.  No side
    effects, no exceptions. *)

val to_shell_ir_unvalidated :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  mode:allowlist_mode ->
  execute_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Lower [input] into {!Masc_exec.Shell_ir.t} without allowlist validation.
    Callers that use the Shell IR facade ([Shell_command_gate.gate_typed])
    should use this entrypoint so validation runs through the facade rather
    than duplicating the allowlist check. *)

val to_shell_ir :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  mode:allowlist_mode ->
  execute_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Validate and lower [input] into {!Masc_exec.Shell_ir.t}.  [Pipeline]
    inputs become an explicit {!Masc_exec.Shell_ir.Pipeline}; literal ["|"]
    argv tokens remain ordinary argument data and never create a pipeline.
    [Exec] argv is passed through as authored; the lowerer does not strip a
    duplicated executable token. [sandbox] defaults to host execution; keeper
    callers may provide Docker runtime targets after sandbox/profile
    resolution. *)

val pp_validation_error : Format.formatter -> validation_error -> unit
(** Human-readable formatter for {!validation_error}.  Stable across
    PR-1/PR-2 — callers may rely on the message structure for log
    classification.  ERROR text intentionally lacks the retired
    path-tokenizer prefix so the 4-layer log amplification is severed
    at PR-2 lexer deletion. *)
