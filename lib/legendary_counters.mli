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
}

val snapshot : unit -> snapshot

val snapshot_to_json : snapshot -> Yojson.Safe.t
(** Stable JSON shape for dashboard / HTTP consumers.  Field names
    mirror the record labels exactly. *)
