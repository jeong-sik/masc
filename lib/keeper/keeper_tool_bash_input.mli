(** Typed argv schema for the keeper_bash tool.

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

type bash_input =
  | Exec of {
      executable : string;
      argv : string list;
      cwd : string option;
      env : (string * string) list;
    }
  | Pipeline of {
      stages : exec_stage list;
      cwd : string option;
      env : (string * string) list;
    }

type allowlist_mode =
  | Dev_full
  | Readonly

type validation_error =
  | Executable_not_allowlisted of {
      name : string;
      mode : allowlist_mode;
    }
  | Empty_argv of { executable : string }
  | Argv_contains_shell_metachar of {
      executable : string;
      index : int;
      token : string;
    }
  | Cwd_not_absolute of string
  | Pipeline_empty
  | Pipeline_too_short
  | Env_key_invalid of string

val of_json : Yojson.Safe.t -> (bash_input, string) result
(** Parse the typed keeper_bash JSON boundary.  Accepts either
    [{executable, argv?, cwd?, env?, timeout_sec?}] for [Exec] or
    [{pipeline = [{executable, argv?}, ...], cwd?, env?}] for [Pipeline].
    [{stages = ...}] is accepted as an equivalent structured pipeline key.
    [timeout_sec] is accepted at this layer and consumed by the caller. Raw
    command-string fields and other unsupported fields are intentionally rejected
    here. *)

val validate : mode:allowlist_mode -> bash_input -> (unit, validation_error) result
(** Run all structural checks against [input].  Returns [Ok ()] on
    success, or the first {!validation_error} encountered.  No side
    effects, no exceptions. *)

val to_shell_ir_unvalidated :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  mode:allowlist_mode ->
  bash_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Lower [input] into {!Masc_exec.Shell_ir.t} without allowlist validation.
    Callers that use the Shell IR facade ([Shell_command_gate.gate_typed])
    should use this entrypoint so validation runs through the facade rather
    than duplicating the allowlist check. *)

val to_shell_ir :
  ?sandbox:Masc_exec.Sandbox_target.t ->
  mode:allowlist_mode ->
  bash_input ->
  (Masc_exec.Shell_ir.t, validation_error) result
(** Validate and lower [input] into {!Masc_exec.Shell_ir.t}.  [Pipeline]
    inputs become an explicit {!Masc_exec.Shell_ir.Pipeline}; literal ["|"]
    argv tokens remain ordinary argument data and never create a pipeline.
    [sandbox] defaults to host execution; keeper callers may provide Docker
    runtime targets after sandbox/profile resolution. *)

val pp_validation_error : Format.formatter -> validation_error -> unit
(** Human-readable formatter for {!validation_error}.  Stable across
    PR-1/PR-2 — callers may rely on the message structure for log
    classification.  ERROR text intentionally lacks the retired
    path-tokenizer prefix so the 4-layer log amplification is severed
    at PR-2 lexer deletion. *)
