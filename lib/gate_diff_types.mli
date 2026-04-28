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

val classify_destructive : string -> (destructive_class * string) option
(** [classify_destructive cmd] returns the first matching
    [(class, substring)] pair in declaration order, or [None] when
    no destructive pattern matches.

    Order matters: longer substrings come first so [rm -rf] matches
    before [rm -r] (both classify as {!Recursive_delete} but the
    returned substring differs).  The returned substring is suitable
    for inclusion in an audit-log diagnostic — it is the literal
    that triggered classification, not a description.

    The substring set mirrors one row per pattern in
    {!Eval_gate.destructive_patterns}.  Drift between the two lists
    means the legacy gate and the shadow gate disagree by
    construction — pinning the order at the contract seam keeps the
    drift detectable.  Case-insensitive substring matching via
    {!String_util.contains_substring_ci}. *)

(** {1 Legacy and shadow verdicts} *)

type legacy_verdict =
  | Legacy_allow
  | Legacy_reject_by_allowlist
  | Legacy_reject_destructive of string
        (** The matching substring from
            [Eval_gate.destructive_patterns], NOT the description. *)

type shadow_verdict =
  | Shadow_allow of { parse_tag : string }
  | Shadow_parse_unsupported of { parse_tag : string }
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
