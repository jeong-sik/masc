(** In-process counters for the Legendary Bash dark-launch observers.

    These counters are incremented only while the matching observer
    env flag is enabled (see [Worker_dev_tools.shadow_diff_log_enabled]
    and [MASC_BASH_AUTO_BG_OBSERVE] in [keeper_exec_shell]), so an
    operator running with observers off pays zero cost.

    All counters are [Atomic.t] and safe to increment from any fiber
    or domain.  The module is a pure sidecar to the log-line stream:
    flipping observers on produces both structured logs (for grep /
    log aggregators) and in-memory totals (for dashboards / HTTP
    snapshot endpoints). *)

val incr_gate_diff : Gate_diff_types.gate_diff -> unit
(** Record one P5 shadow-gate call under the given bucket.  Always
    increments [gate_diff_total] in the snapshot. *)

val incr_auto_bg_observed : promoted_candidate:bool -> unit
(** Record one P4 foreground-only call that the observer inspected.
    When [promoted_candidate] is [true] the elapsed duration would
    have tripped [MASC_BLOCKING_BUDGET_MS]. *)

val incr_too_complex_by_tag : string -> unit
(** Record one shadow rejection attributable to a subset-excluded
    bash construct.  [tag] is the [parse_tag] string emitted by
    [Worker_dev_tools.shadow_parse_outcome] — accepted forms are the
    full [too_complex:<reason>] prefix or the bare [<reason>] suffix.
    Unknown reasons are bucketed under [too_complex_other] so the
    total is always consistent with [gate_diff_shadow_cannot_parse].

    Callers should invoke this IN ADDITION to [incr_gate_diff
    `Shadow_cannot_parse] — the per-reason buckets are a histogram
    refinement of that single bucket, not a replacement. *)

val reset : unit -> unit
(** Zero every counter.  Used by tests; operators should not rely on
    this surface. *)

type snapshot = {
  gate_diff_total : int;
  gate_diff_agree : int;
  gate_diff_legacy_allow_shadow_deny : int;
  gate_diff_legacy_deny_shadow_allow : int;
  gate_diff_shadow_cannot_parse : int;
  auto_bg_observed : int;
  auto_bg_would_have_promoted : int;
  (* Per-reason histogram of the shadow_cannot_parse bucket.  Mirrors
     [Parsed.reason_too_complex] 1:1 except for [Unknown_construct]
     which collapses into [too_complex_other].  The sum of the
     per-reason buckets plus [too_complex_parse_error] plus
     [too_complex_parse_aborted] plus [too_complex_other] matches
     [gate_diff_shadow_cannot_parse]. *)
  too_complex_redirect : int;
  too_complex_logic_op : int;
  too_complex_heredoc : int;
  too_complex_here_string : int;
  too_complex_cmd_subst : int;
  too_complex_proc_subst : int;
  too_complex_subshell : int;
  too_complex_arith_expansion : int;
  too_complex_control_flow : int;
  too_complex_function_def : int;
  too_complex_glob_brace : int;
  too_complex_background : int;
  too_complex_parse_error : int;
  too_complex_parse_aborted : int;
  too_complex_other : int;
}

val snapshot : unit -> snapshot

val snapshot_to_json : snapshot -> Yojson.Safe.t
(** Stable JSON shape for dashboard / HTTP consumers.  Field names
    mirror the record labels exactly. *)

(** {2 Derived ratios}

    Pure functions over [snapshot] that encapsulate the flip-decision
    math documented in [LEGENDARY-BASH-RUNBOOK.md].  Dashboards, the
    [/api/v1/legendary_bash/shadow_counters] JSON surface, and
    operator shell recipes should prefer these helpers over
    re-implementing the same numerator / denominator pairing.  All
    functions return [0.0] when their denominator is zero — the
    "observer off" read must be safely serialisable as a finite
    float (no NaN / inf in the JSON output). *)

val disagree_ratio : snapshot -> float
(** [(gate_diff_legacy_allow_shadow_deny +
        gate_diff_legacy_deny_shadow_allow)
     / gate_diff_total].

    Fraction of P5 gate calls where the legacy regex gate and the new
    AST gate produced opposite verdicts, excluding [`Shadow_cannot_parse].
    Drives the [MASC_BASH_AST_ONLY] flip criterion (target 0.0 over a
    rolling 7-day window). *)

val shadow_parse_coverage : snapshot -> float
(** [1.0 - gate_diff_shadow_cannot_parse / gate_diff_total].

    Fraction of observed P5 calls that the AST gate could fully parse
    (i.e., the shadow verdict was either [`Agree] or an actual
    disagreement, not a parser bailout).  Drives the "parse gap
    < 1%" flip criterion in the runbook — a coverage of [0.99] or
    higher is the flip target. *)

val auto_bg_promotion_rate : snapshot -> float
(** [auto_bg_would_have_promoted / auto_bg_observed].

    Fraction of P4 observed foreground calls that exceeded
    [MASC_BLOCKING_BUDGET_MS].  Guides both the [MASC_BLOCKING_BUDGET_MS]
    tuning ("would promotion fire too often?") and the
    [MASC_BASH_AUTO_BG] default-flip decision ("is promotion rare
    enough to be tolerable?"). *)

val snapshot_to_json_with_ratios : snapshot -> Yojson.Safe.t
(** Same flat field set as {!snapshot_to_json}, with an additional
    ["ratios"] sibling object containing the three derived ratios
    ({!disagree_ratio}, {!shadow_parse_coverage},
    {!auto_bg_promotion_rate}).  Consumers that prefer server-computed
    flip-decision math over client-side arithmetic should call this
    helper; the flat fields remain a 1:1 mirror of {!snapshot} so
    existing dashboards keep working.  All ratio values are finite
    ([0.0] when the denominator is zero), so the output remains a
    valid JSON document regardless of observer state. *)
