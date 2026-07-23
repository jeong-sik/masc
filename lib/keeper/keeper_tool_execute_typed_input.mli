(** Typed process-vector schema for Execute.

    Introduced by RFC-0091 PR-1 (§5.1.1) to replace raw
    command-string parsing with a structured non-empty argv boundary.

    {2 Design constraints}

    - **No shell-string parsing**.  Validation is structural only:
      argv/cwd/env/redirect shape is checked here, while external-effect
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

type exec_stage = { argv : string list }

type redirect_target =
  | Inherit
      (** default; child inherits the parent's file descriptor *)
  | Discard
      (** discard output / read empty input — equivalent to [/dev/null] *)
  | File of string
      (** absolute filesystem path.  stdout/stderr open for writing,
          stdin opens for reading. *)

type execute_input =
  | Exec of {
      argv : string list;
      cwd : string option;
      env : (string * string) list;
      timeout_sec : float option;
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
      timeout_sec : float option;
    }
      (** Per-stage redirects are intentionally not exposed here — pipe
          construction owns the inter-stage fd plumbing.  Out-of-stage
          redirects on the pipeline's endpoints are a deferred extension. *)

type validation_error =
  | Empty_argv
  | Empty_program
  | Argv_contains_nul of {
      index : int;
      token : string;
    }
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
    [{argv = [program; arg...], cwd?, env?, timeout_sec?}] for [Exec] or
    [{pipeline = [{argv = [program; arg...]}, ...], cwd?, env?}] for [Pipeline].
    [timeout_sec] is preserved as an explicit optional execution boundary;
    absence means unbounded execution.
    [argv] and [pipeline] together, raw command-string fields, [{stages =
    ...}], and other unsupported fields are intentionally rejected here.  No
    compatibility normalization is applied at parse time.  The removed
    [executable] field is rejected as an unsupported field. *)

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

val to_shell_ir :
  ?sandbox:Masc_exec.Sandbox_target.t ->
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
