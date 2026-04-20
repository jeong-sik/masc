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

type gate_diff_tag =
  [ `Agree
  | `Legacy_allow_shadow_deny
  | `Legacy_deny_shadow_allow
  | `Shadow_cannot_parse
  ]
(** Categorical buckets mirroring [Worker_dev_tools.gate_diff] 1:1.
    [`Agree] is recorded even though it is not logged, so the
    denominator for "disagree rate" is observable. *)

val incr_gate_diff : gate_diff_tag -> unit
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
