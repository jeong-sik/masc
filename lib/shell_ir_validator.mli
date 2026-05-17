(** Shell_ir_validator — typed validation advisor for keeper_bash.

    RFC-0092 Phase A core module.  Pure function; no production
    caller yet (Phase A wiring lands in PR-2 / RFC-0092 §4.1).

    Given a raw bash command + an allowlist of binary names, parses
    the command through {!Masc_exec_bash_parser.Bash.parse_string}
    and returns a typed {!advisory}:

    - {!Allow} — AST parsed as a simple command (or a pipeline of
      simple commands) and every binary is in the allowlist.
    - {!Reject} — AST parsed but at least one binary is outside
      the allowlist.
    - {!Cannot_parse} — parser surfaced [Parse_error] /
      [Parse_aborted] / [Too_complex].  The caller must decide
      whether to fall back to the legacy substring gate or treat
      [Cannot_parse] as a deny.

    The advisor does NOT consume destructive / evasion patterns —
    those checks remain in {!Eval_gate} and run on the raw string
    before the typed path (per RFC-0092 §4.5).  This module's
    sole job is allowlist enforcement over the typed AST. *)

(** Why the parser bailed.  Mirrors {!Parsed.t} sans the
    [Parsed _] AST payload — the validator only cares about the
    non-success arms. *)
type cannot_parse_kind =
  | Parse_error
  | Parse_aborted of Masc_exec.Parsed.reason_aborted
  | Too_complex of Masc_exec.Parsed.reason_too_complex

type reject_reason =
  | Command_not_in_allowlist of string
      (** Single-command reject — the [string] is the offending
          binary name as returned by [Masc_exec.Bin.to_string]. *)
  | Pipeline_segment_disallowed of string
      (** Pipeline reject — at least one pipeline segment's binary
          is outside the allowlist.  The [string] is the first
          offending binary name (left-to-right). *)

type advisory =
  | Allow
  | Reject of { reason : reject_reason; diagnostic : string }
  | Cannot_parse of { kind : cannot_parse_kind }

val advise : cmd:string -> allowlist:string list -> advisory
(** Run the typed advisor.  Pure; no env reads, no file I/O, no
    destructive-pattern checks.

    Allowlist matching is exact-equal on [Masc_exec.Bin.to_string]
    output, so callers control normalisation (lowercase, etc.) by
    pre-processing the allowlist.

    Returns [Cannot_parse _] for any parser bailout — the caller
    decides the fallback (legacy gate, deny, ask, etc.). *)

val advisory_tag : advisory -> string
(** Stable snake_case tag for log / metric emission:
    [Allow -> "allow"], [Reject _ -> "reject"],
    [Cannot_parse _ -> "cannot_parse"].  Pin the wording — future
    dashboard rules grep on these literals. *)

val cannot_parse_kind_tag : cannot_parse_kind -> string
(** Stable snake_case sub-tag for the [Cannot_parse] arm.  Pinned
    1:1 to the [too_complex_*] / [parse_*] field names in
    {!Legendary_counters.snapshot} so a dashboard histogram of
    typed-advisor bailouts can grep the same literals already used
    by the substring-gate shadow counters:

    {ul
      {- [Parse_error -> "parse_error"]}
      {- [Parse_aborted `Timeout_50ms -> "timeout"]}
      {- [Parse_aborted `Depth_limit -> "depth_limit"]}
      {- [Parse_aborted `Token_limit_50k -> "token_limit"]}
      {- [Too_complex `Heredoc -> "heredoc"]}
      {- [Too_complex `Here_string -> "here_string"]}
      {- [Too_complex `Cmd_subst -> "cmd_subst"]}
      {- [Too_complex `Proc_subst -> "proc_subst"]}
      {- [Too_complex `Subshell -> "subshell"]}
      {- [Too_complex `Arith_expansion -> "arith_expansion"]}
      {- [Too_complex `Control_flow -> "control_flow"]}
      {- [Too_complex `Logic_op -> "logic_op"]}
      {- [Too_complex `Function_def -> "function_def"]}
      {- [Too_complex `Glob_brace -> "glob_brace"]}
      {- [Too_complex `Background -> "background"]}
      {- [Too_complex `Redirect -> "redirect"]}
      {- [Too_complex (`Unknown_construct _) -> "other"]}
    }

    Adding a new variant in {!Masc_exec.Parsed.reason_too_complex}
    or [reason_aborted] forces an exhaustive-match update here at
    compile time — the catch-all sits only on the
    [`Unknown_construct] arm where the substring payload is already
    free-form and not stable. *)

val reject_reason_tag : reject_reason -> string
(** Stable snake_case sub-tag for the [Reject] arm: pinpoints
    whether the reject came from a single command or a pipeline
    segment without leaking the offending binary name into the
    metric label.  Pinned values:

    {ul
      {- [Command_not_in_allowlist _ -> "command"]}
      {- [Pipeline_segment_disallowed _ -> "pipeline_segment"]}
    } *)
