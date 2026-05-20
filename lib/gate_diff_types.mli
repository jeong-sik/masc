(** Gate_diff_types — shared shell safety helper definitions.

    Owns the destructive-command taxonomy, command log hashing, and
    dynamic typed-shell predicates that remain live. The old
    legacy-vs-AST gate diff observer is intentionally absent. *)

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

(** Single source of truth for one destructive shell pattern. Carries
    its substring (matched case-insensitively), its operator-visible
    description, and its typed {!destructive_class}. *)
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
    both walk this list. *)

val classify_destructive : string -> (destructive_class * string) option
(** [classify_destructive cmd] returns the first matching
    [(class, substring)] pair in declaration order over
    {!destructive_patterns}, or [None] when no pattern matches.

    The returned substring is suitable for inclusion in an audit-log
    diagnostic — it is the literal that triggered classification,
    not a description.  Case-insensitive substring matching via
    {!String_util.contains_substring_ci}. *)

(** {1 Logging utilities} *)

val cmd_hash_for_log : string -> string
(** [cmd_hash_for_log cmd] returns a deterministic 12-hex-char prefix
    of [Digest.string cmd] suitable for log de-duplication.  The
    12-char width is a contract — log aggregators dedupe on this
    exact prefix length.  A future "let's use 16 chars for
    collision safety" change must coordinate with the log pipeline. *)

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
