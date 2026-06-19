(** Completion_trust_audit — the RFC-0262 §9 metric, computed offline over the
    task-transition event log.

    RFC-0262 Phase 1 typed task completion as a closed [completion_authority]
    sum and Phase 2 flipped peer force-completion to default-deny. Neither phase
    changes the metric by itself — they exist so the §9 invariant becomes
    *checkable*. This module is that check: a pure fold over the transition log
    (the lines emitted by [Workspace_task_classify.transition_log_event]) into
    the two §9 quantities.

    §9, verbatim: "zero foreign-task completions by a non-[Operator]/[System]
    actor in the live log, and no [Done] reachable from a force-equivalent path
    that skipped the evidence gate."

    Ownership comes from one of two sources, in order of preference:
    - the [assignee] field the transition itself records (RFC-0262 §9) — the
      task's owner immediately before completion. This is exact and needs no
      history.
    - failing that (legacy lines predating the field), *reconstruction* from the
      event stream: the fold tracks [task -> current claimant] from claim /
      release / cancel transitions and cross-checks it at each completion.

    The [authority] label refines the force-equivalent breakdown ([Operator]
    override vs [System] code-path satisfier).

    The fold assumes its input is in chronological order (the order daily JSONL
    files are appended). For a *legacy* completion whose claim is outside the fed
    window the owner is unknown, so it is [Indeterminate], never a violation —
    "indeterminate dominates", mirroring {!Deterministic_evidence_evaluator}. A
    completion carrying a logged [assignee] is never indeterminate. *)

type authority =
  | Assignee  (** RFC-0262 [authority="assignee"] — actor completing its own claim *)
  | Operator  (** [authority="operator"] — operator control plane / admin override *)
  | System  (** [authority="system"] — code-path satisfier (RFC-0199 probe, GC) *)
  | Legacy_forced
      (** pre-RFC-0262 line: no [authority] field, [forced]=true (force-equivalent) *)
  | Legacy_unforced
      (** pre-RFC-0262 line: no [authority] field, [forced]=false (self-claim) *)
  | Unknown of string  (** an [authority] label this version does not recognise *)

type done_record = {
  task_id : string;
  actor : string;
  authority : authority;
  assignee : string option;  (** reconstructed claimant, [None] if claim out of window *)
  ts : string;
}

type metric = {
  done_total : int;
  done_assignee : int;
  done_operator : int;
  done_system : int;
  done_legacy_forced : int;
  done_legacy_unforced : int;
  done_unknown_authority : int;
  foreign_assignee_completions : done_record list;
      (** §9①: a non-[Operator]/[System] actor (authority [Assignee] /
          [Legacy_unforced]) *directly* completed a *foreign* task
          ([from_status] claimed / in_progress, i.e. a [Done_action]). MUST be
          empty. Verification approvals are excluded — see
          [verification_approvals]. *)
  verification_approvals : int;
      (** completions reached via [Approve_verification]
          ([from_status="awaiting_verification"]). The actor here is the bound
          verifier, which the FSM *requires* to differ from the assignee
          (cross-agent verification, #4); such a completion is never a §9①
          violation. Counted separately so the foreign-completion check is not
          fooled by the verification protocol. *)
  force_equivalent_completions : int;
      (** §9②: completions via [Operator] / [System] / [Legacy_forced] — the
          force-equivalent paths. Phase-3 baseline: every one of these currently
          skips the evidence gate (RFC-0199 Phase B wires it). *)
  indeterminate_ownership : int;
      (** completions whose claim was outside the fed window — ownership unknown,
          not counted as a violation. *)
  events_parsed : int;
  events_skipped : int;  (** non-object / unparseable lines *)
}

val empty_metric : metric

val authority_to_string : authority -> string

val audit_events : Yojson.Safe.t list -> metric
(** Fold a chronological transition-event stream into the §9 metric. Pure:
    ownership is reconstructed per call, nothing is read from disk. *)

val metric_to_json : metric -> Yojson.Safe.t

val metric_to_summary : metric -> string
(** Human-readable one-screen report, including the §9 verdict
    (PASS when [foreign_assignee_completions] is empty). *)
