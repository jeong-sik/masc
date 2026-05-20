(** Gate_diff_types — shared type definitions for shell command safety
    classification.

    Three closed variant taxonomies and the diff function over them:

    - {!destructive_class}: 8 named classes of destructive shell
      operations (recursive delete, SQL drop, forced git mutation, ...)
    - {!legacy_verdict} / {!shadow_verdict}: the legacy substring-match
      gate vs the shadow AST-based gate verdicts
    - {!gate_diff}: the four reconciliation outcomes between the two

    Extracted from [worker_dev_tools.ml] so lightweight consumers
    (counters, telemetry) can reference the types without pulling in
    the full command-validation tool surface.  Classification functions
    that depend on [worker_dev_tools] internals (validate_command,
    shadow_parse_outcome) stay in [worker_dev_tools.ml] and consume
    these types via [Gate_diff_types.t].

    Both {!destructive_class} and {!gate_diff} are intentionally closed
    variants — adding a new class / outcome must touch every match
    site at compile time.  The existing call sites in [keeper_exec_shell]
    and [legendary_counters] depend on this exhaustiveness for their
    metric / log key set. *)

(** {1 Destructive command classes} *)

type destructive_class =
  | Recursive_delete       (** [rm -rf] / [rm -r] / [rmdir] *)
  | Sql_destructive        (** [drop table], [drop database], [truncate], [delete from] *)
  | Forced_git_mutation    (** [git push --force], [git reset --hard], [git clean -f] *)
  | Privilege_escalation   (** [chmod 777] *)
  | Filesystem_format      (** [mkfs] *)
  | Device_write           (** [> /dev/], [dd if=] *)
  | Process_signal         (** [kill -9], [pkill] *)
  | System_control         (** [shutdown], [reboot] *)

val destructive_class_to_string : destructive_class -> string
(** [destructive_class_to_string c] returns the canonical
    snake_case tag (e.g. [Recursive_delete -> "recursive_delete"]).
    The wording is the operator-visible metric / log key — runbook
    alerts grep on these literals.  Do not change without a
    coordinated metric-rename PR. *)

(** Single source of truth for one destructive shell pattern.  Carries
    its substring (matched case-insensitively), its operator-visible
    description, and its typed {!destructive_class}.  Replaces the
    previously parallel [Eval_gate.destructive_patterns]
    [(pattern, desc)] list and [destructive_class_substrings]
    [(pattern, class)] list — both derive from this catalogue, so
    drift between the legacy gate and the shadow classifier is
    impossible by construction. *)
type destructive_pattern = {
  class_ : destructive_class;
  pattern : string;
  description : string;
}

val destructive_patterns : destructive_pattern list
(** The canonical destructive-pattern catalogue.

    Order matters: longer substrings come first so [rm -rf] matches
    before [rm -r] (both classify as {!Recursive_delete} but the
    returned substring differs).

    Length is pinned at 19 by [test_destructive_class.test_coverage_count]
    — a new entry must update that count.  The list is the only
    SSOT; [Eval_gate.destructive_patterns] and {!classify_destructive}
    both walk this list, eliminating the previous drift surface
    enforced only at runtime test time. *)

val classify_destructive : string -> (destructive_class * string) option
(** [classify_destructive cmd] returns the first matching
    [(class, substring)] pair in declaration order over
    {!destructive_patterns}, or [None] when no pattern matches.

    The returned substring is suitable for inclusion in an audit-log
    diagnostic — it is the literal that triggered classification,
    not a description.  Case-insensitive substring matching via
    {!String_util.contains_substring_ci}. *)

(** {1 Legacy and shadow verdicts} *)

type legacy_verdict =
  | Legacy_allow
  | Legacy_reject_by_allowlist
  | Legacy_reject_destructive of string
        (** The matching substring from
            [Eval_gate.destructive_patterns], NOT the description. *)

(** Outcome of running the bash subset parser on a candidate command.
    1:1 with [Masc_exec.Parsed.t] excluding the payload [Parsed _]
    (the shadow gate only cares about the parse classification, not
    the AST itself). Typed so that downstream histogram dispatch
    is exhaustive — a new [Parsed.reason_too_complex] variant fails
    to compile rather than silently landing in a catch-all bucket. *)
type parse_outcome_kind =
  | Parsed_simple
  | Parse_error
  | Parse_aborted of Masc_exec.Parsed.reason_aborted
  | Too_complex of Masc_exec.Parsed.reason_too_complex

val parse_outcome_kind_to_tag : parse_outcome_kind -> string
(** Stable snake_case rendering. Matches the legacy
    [shadow_parse_outcome] string surface byte-for-byte so log
    aggregators / runbook greps continue to see the same tag set:
    [Parsed_simple -> "parsed_simple"],
    [Parse_error -> "parse_error"],
    [Parse_aborted r -> "parse_aborted:<r>"],
    [Too_complex r -> "too_complex:<r>"].
    Pin the wording — operator alerts grep on these literals. *)

type shadow_verdict =
  | Shadow_allow
        (** Shadow parsed the command as a simple command (the only
            parse outcome that yields an allow verdict at this layer).
            Carries no payload — the [Parsed_simple] kind is implicit. *)
  | Shadow_parse_unsupported of { kind : parse_outcome_kind }
        (** Shadow could not parse the command. [kind] is one of
            [Parse_error] / [Parse_aborted _] / [Too_complex _];
            [Parsed_simple] is excluded by construction. *)
  | Shadow_deny_destructive of destructive_class * string

(** {1 Gate diff} *)

type gate_diff =
  | Agree
  | Legacy_allow_shadow_deny       (** Legacy permits, shadow denies — flag flip risk *)
  | Legacy_deny_shadow_allow       (** Legacy denies, shadow permits — over-rejection by legacy *)
  | Shadow_cannot_parse            (** Shadow could not parse — diff is undefined *)

val gate_diff_to_string : gate_diff -> string
(** [gate_diff_to_string d] returns the canonical snake_case tag
    used as the metric label key.  Pinned wording — alerts grep on
    these literals. *)

val diff_of_verdicts :
  legacy:legacy_verdict -> shadow:shadow_verdict -> gate_diff
(** [diff_of_verdicts ~legacy ~shadow] computes the reconciliation
    outcome.  Decision order at the contract seam:

    1. {!Shadow_parse_unsupported} -> {!Shadow_cannot_parse}
       (regardless of legacy verdict — undefined diff dominates).
    2. ([Legacy_allow], [Shadow_allow]) -> {!Agree}.
    3. {!Legacy_reject_by_allowlist} -> {!Agree} (legacy short-
       circuits before destructive classification — the shadow
       verdict is irrelevant).
    4. ([Legacy_reject_destructive], [Shadow_deny_destructive]) ->
       {!Agree} (both deny on destructive grounds; the matching
       substring may differ but the outcome is consistent).
    5. ([Legacy_allow], [Shadow_deny_destructive]) ->
       {!Legacy_allow_shadow_deny} (the canonical "shadow caught
       something legacy missed" signal — drives the flag-flip
       decision).
    6. ([Legacy_reject_destructive], [Shadow_allow]) ->
       {!Legacy_deny_shadow_allow} (legacy over-rejection — drives
       allowlist refinement).

    The function is total: every legacy/shadow pair has a defined
    outcome.  A future variant addition on either input type forces
    every arm here to be revisited. *)

val legacy_verdict_to_tag : legacy_verdict -> string
(** [legacy_verdict_to_tag v] returns the snake_case payload-free tag
    (e.g. [Legacy_reject_destructive _ -> "legacy_reject_destructive"]).
    Used as a log field key — pinned wording. *)

val shadow_verdict_to_tag : shadow_verdict -> string
(** [shadow_verdict_to_tag v] returns the snake_case payload-free tag.
    Used as a log field key — pinned wording. *)

(** {1 Logging utilities} *)

val cmd_hash_for_log : string -> string
(** [cmd_hash_for_log cmd] returns a deterministic 12-hex-char prefix
    of [Digest.string cmd] suitable for log de-duplication.  The
    12-char width is a contract — log aggregators dedupe on this
    exact prefix length.  A future "let's use 16 chars for
    collision safety" change must coordinate with the log pipeline. *)

val shadow_diff_log_enabled : unit -> bool
(** [shadow_diff_log_enabled ()] returns [true] iff the
    [MASC_BASH_AST_SHADOW_LOG] environment variable is set to one
    of the documented truthy values: [1], [true], [TRUE], [yes],
    [on], [log].  Any other value (including unset) returns
    [false] — the gate logs nothing by default. *)

val typed_advisor_log_enabled : unit -> bool
(** RFC-0092 Phase A advisor opt-in.  Returns [true] iff the
    [MASC_BASH_TYPED_ADVISOR] environment variable is set to one of
    the documented truthy values: [1], [true], [TRUE], [yes], [on],
    [log].  Default off — the typed-validation parity-measurement
    counters do not increment until an operator opts in.  Phase C
    flips authority via the separate {!typed_authority_enabled}
    flag below; advisor logging remains independent so operators
    can keep parity counters running after authority is enabled. *)

val typed_authority_enabled : unit -> bool
(** RFC-0092 Phase C authority opt-in — predicate-only stage of PR-4.
    Returns [true] iff the [MASC_BASH_TYPED_AUTHORITY] environment
    variable is set to one of the documented truthy values: [1],
    [true], [TRUE], [yes], [on].  Default off — *no behavior change
    while unset*.  When set, downstream callers (planned:
    [keeper_shell_bash]) treat the typed {!Shell_ir_validator} verdict
    as authoritative for [Allow]/[Reject] cases and fall back to the
    legacy substring gate on [Cannot_parse], per RFC-0092 §4.3.  This
    predicate is the SSOT operators flip; consumers must not read
    [Sys.getenv] directly for this flag.

    Distinct from {!typed_advisor_log_enabled}: the advisor flag gates
    *measurement* (parity counters), the authority flag gates
    *decision*.  An operator may run with advisor on + authority off
    (Phase B observation) or advisor off + authority on (Phase C
    after parity criterion met); the two flags are independent
    booleans by design.

    Truthy-value set is intentionally narrower than the advisor flag
    (no [log] alias) because [log] only makes sense for measurement,
    not decisions. *)
