(** Parse-once SSOT facade for shell command validation.

    Phase 1 of the Shell IR Promotion Goal Plan (2026-05-18). Lives
    in [lib/exec/command_gate/] as the [masc_exec_command_gate]
    sub-library so it can depend on both [masc_exec] (Shell_ir /
    Parsed / Bin / Sandbox_target) and [masc_exec_bash_parser]
    (the bash subset parser) without introducing a cycle through
    [masc_exec].

    This module is the canonical bridge between raw shell strings and
    the Shell IR. The Plan's design goal is that one parse produces
    one [verdict], which validation, telemetry, native dispatch, path
    validation, and exit classification all share.

    The lib-root [Masc_mcp.Shell_command_gate] transition facade has
    been retired. Raw-string boundaries use [gate_raw] to cross into
    Shell IR once; typed callers use [gate_typed] or
    [lower_typed_pipeline] directly.

    Output verdict separates the four operational classes the Plan's
    Goal Tree distinguishes:

    - [Allow] — parsed, every stage passes policy, dispatch eligible.
    - [Reject] — parsed, but policy denied a stage.
    - [Cannot_parse] — the bash subset parser rejected or aborted on
      the input.
    - [Too_complex] — parsed grammar but contains a construct the
      subset deliberately excludes (heredoc, cmd_subst, ...) or
      yields a nested pipeline that Phase 1 declines to flatten.

    Pipelines are first-class. [a | b | c] is preserved as a
    non-nested ordered stage list of length three. Nested pipelines
    (a pipeline stage whose AST is itself a [Pipeline]) surface as
    [Too_complex Unsupported_nested_pipeline] so the Plan's
    composition contract (G2.2) is enforced at the facade boundary
    rather than emerging as a silent behavior in dispatch. *)

(** Caller identity for telemetry partition.

    The optional [?caller] arg on {!gate_typed} and
    {!lower_typed_pipeline} is part of the stable caller/verdict
    telemetry surface. The gate verdict itself is independent of the
    caller tag. *)
type caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

(** Parsed-but-rejected reasons. *)
type reject_reason =
  | Command_not_in_allowlist of { bin : string }
  | Pipeline_segment_disallowed of { stage : int; bin : string }
  | Pipes_not_allowed of { stages : int }
  | Redirect_disallowed_in_caller of { stage : int }
  | Path_outside_policy of { stage : int; raw_path : string; diagnostic : string }

(** Parser failure modes that prevent any IR being formed. *)
type parse_reason =
  | Parse_error
  | Parse_aborted of Masc_exec.Parsed.reason_aborted

(** Constructs that parsed but the Phase 1 subset declines to handle.
    [Unsupported_nested_pipeline] is a Phase 1 invariant, not a
    parser limitation — the bash_subset grammar can yield nested
    pipelines through [lower_typed_pipeline]; the facade rejects them
    here so callers do not need a flatten policy in their own code.

    [Unsupported_construct] mirrors
    {!Masc_exec.Parsed.reason_too_complex} for every subset-excluded
    construct the parser already classifies. *)
type too_complex_reason =
  | Unsupported_nested_pipeline
  | Unsupported_construct of Masc_exec.Parsed.reason_too_complex

(** Reusable parse context. [stages] is the ordered Simple list as
    parsed; [stage_bins] is the binary name of each stage in order;
    [direct_dune_seen] is true when any stage directly runs [dune]
    or wraps it through known transparent command runners such as
    [env] or [opam exec].
    Invariants:

    - [stages <> []] always — empty input yields {!Cannot_parse},
      never an [Allow] context.
    - [List.length stages = List.length stage_bins].
    - No element of [stages] is itself a
      {!Masc_exec.Shell_ir.Pipeline} — nested pipelines surface as
      {!Too_complex Unsupported_nested_pipeline}. *)
type parsed_context = {
  ast : Masc_exec.Shell_ir.t;
  stages : Masc_exec.Shell_ir.simple list;
  stage_bins : string list;
  direct_dune_seen : bool;
}

(** Phase 1 verdict surface — four arms matching the Plan's typed
    output. [Allow] carries the [parsed_context] callers reuse for
    telemetry / dispatch / path classification. *)
type verdict =
  | Allow of parsed_context
  | Reject of {
      context : parsed_context;
      reason : reject_reason;
      diagnostic : string;
    }
  | Cannot_parse of { reason : parse_reason }
  | Too_complex of { reason : too_complex_reason }

(** Allowlist policy. [allow_pipes = true] keeps the existing legacy
    behavior; [false] yields {!Pipes_not_allowed} for any pipeline with
    two or more stages. Redirects are always rejected, including fd-to-fd redirects such as
    syntax, including fd-to-fd redirects such as [2>&1]. *)
type allowlist_policy = {
  redirect_allowed : bool;
  allowed_commands : string list;
  allow_pipes : bool;
  
}

(** Path policy applied to literal path arguments and file redirect
    targets of every stage.
    Phase 1 intentionally keeps the policy minimal — only an opt-in
    classifier callback is consulted, so the facade itself does no
    [Path_scope] decision-making and instead defers to the caller. *)
type path_policy = {
  classify : (raw_path:string -> [ `Allow | `Deny of string ]) option;
}

(** Sandbox context. Phase 1 uses this purely for evidence (echoed
    back through every stage's
    [Masc_exec.Shell_ir.simple.sandbox] field). Native dispatch
    wiring is Phase 4. *)
type sandbox_context = {
  target : Masc_exec.Sandbox_target.t;
}

val allow_all_paths : path_policy
(** A path policy that approves every literal — useful when the
    caller has its own validator and only wants the Shell IR parse +
    allowlist check. *)

val host_sandbox : sandbox_context
(** Convenience: the default {!Masc_exec.Sandbox_target.host}
    sandbox. *)

val gate_typed
  :  ?caller:caller
  -> ir:Masc_exec.Shell_ir.t
  -> allowlist:allowlist_policy
  -> path_policy:path_policy
  -> sandbox:sandbox_context
  -> unit
  -> verdict
(** Policy-aware typed entrypoint for callers that already have a
    {!Masc_exec.Shell_ir.t}. This bypasses raw Bash parsing but shares
    the same allowlist, redirect, path-policy, sandbox, and nested
    pipeline handling as the legacy [gate] entrypoint. *)

val gate_raw
  :  ?caller:caller
  -> text:string
  -> allowlist:allowlist_policy
  -> path_policy:path_policy
  -> sandbox:sandbox_context
  -> unit
  -> verdict
(** Raw-string entrypoint for shell frontends that have not yet crossed
    the Shell IR boundary. Centralizing this parser call keeps
    [Bash.parse_string] ownership inside this command-gate library
    while preserving the same {!verdict} surface as {!gate_typed}. *)

val lower_typed_pipeline
  :  ?caller:caller
  -> stages:Masc_exec.Shell_ir.simple list
  -> sandbox:sandbox_context
  -> unit
  -> verdict
(** Lower a typed pipeline (e.g. from {!Keeper_tool_bash_input}) into
    the same {!verdict} shape. Empty input yields {!Cannot_parse
    Parse_error}; a single stage yields [Allow] with a [Simple] AST;
    multiple stages yield [Allow] with a non-nested
    [Pipeline]. Nested pipelines are forbidden because the input type
    already guarantees [Simple] stages — this helper exists so typed
    input shares the {!verdict} surface with raw input.  [?caller] is
    captured for the upcoming telemetry partition (RFC-0131 PR-3) and
    does not affect the verdict. *)

(** {1 Tags for telemetry} *)

val caller_tag : caller -> string
val verdict_tag : verdict -> string
val reject_reason_tag : reject_reason -> string
val parse_reason_tag : parse_reason -> string
val too_complex_reason_tag : too_complex_reason -> string

(** {1 Context inspection} *)

val stage_count : parsed_context -> int
val last_stage_bin : parsed_context -> string option
val is_pipeline : parsed_context -> bool
