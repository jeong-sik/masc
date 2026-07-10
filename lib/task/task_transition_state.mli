(** Typed escalation state for repeated [Invalid task state] transition
    errors emitted by [Tool_task.run_task_transition].

    Background
    ──────────
    [Tool_task] returns [Masc_error.TaskError (InvalidState _)] when an
    agent attempts a [task_action] that the current [task_status] does
    not permit. The error itself is correct — the transition cannot be
    allowed — but the call sites at [Tool_task.handle_done_transition]
    (line 689) and [Tool_task.run_task_transition] (line 975) log every
    such failure at ERROR. In production the same [(task, action, from)]
    tuple is retried by the same agent (or by alias resolvers) within
    seconds, and the result is a recurrent ERROR-level log loop visible
    in system_log_2026-05-19:

    - 2026-05-19 00:00–00:30 slice: 7 [task transition failed: [TaskError]
      Invalid task state] ERROR lines / 10 min (down from 17/10 min the
      previous slice).
    - Steady-state projection: ~10–15K events/day if the upstream caller
      pattern stabilises.

    Top patterns observed (system_log 2026-05-19, normalised):
    {[
      6  Invalid transition: done -> approve / submit_for_verification
      5  task is already done by AGENT
      3  Self-approval not allowed
      3  task is awaiting verification by AGENT
      3  Invalid transition: todo -> start
      3  Invalid transition: awaiting_verification -> claim
      …  (Invalid transition: claimed -> release; in_progress -> reject; …)
    ]}

    The block itself is *not* the bug — the bug is that the operator
    sees the same fact restated repeatedly per task. This module records
    each failure under a closed-sum [family] fingerprint and classifies
    the result so the caller can emit one durable [`Threshold_silence]
    ERROR plus a Otel_metric_store counter, and demote noisy intermediate
    emissions to DEBUG.

    Closed sum types, no catch-all. The [family] enum captures every
    distinct error class produced by [Tool_task.validate_transition] and
    the [transition_action] enum mirrors [Types_core.task_action]
    one-for-one, so adding a new task action upstream forces a compile-
    time update here.

    Workaround posture
    ──────────────────
    This is a *symptom suppression* layer for the log surface. The
    root fix lives one level up in [Tool_task.run_task_transition] and
    the upstream callers — an invalid transition should be detected
    client-side (cached [task_status] + valid_next_actions) before the
    transition is even attempted, so the same [(task, action, from)]
    tuple is not retried 5–7× per task. That change touches the
    agent tool-call loop and the agent SDK retry semantics and is
    deferred to its own RFC.

    For now, the [`Threshold_silence] outcome gives the operator a
    one-line ERROR after [default_silence_threshold] identical failures
    and a Otel_metric_store counter for dashboarding; subsequent failures
    return [`Repeated] and the caller is expected to DEBUG-log instead
    of ERROR-log.

    [WORKAROUND-CARRYOVER]: this module is a noise-dedupe layer, not
    a structural fix for the upstream invalid-transition retry pattern.
    Track the root fix on a follow-up issue.

    Threading
    ─────────
    Backed by an in-memory [Hashtbl.t] under a [Mutex]. Process
    lifetime; not persisted. A server restart sees the first
    occurrence emit at ERROR again, which is the desired behaviour
    (operator-visible "this is still happening after restart"). *)

(** Closed-enum mirror of [Types_core.task_status] constructors,
    projected to the data-free status kind used for fingerprinting.
    Adding a new constructor upstream forces an arm here. *)
type status_kind =
  | Todo_kind
  | Claimed_kind
  | InProgress_kind
  | AwaitingVerification_kind
  | Done_kind
  | Cancelled_kind
  | Operator_blocked_kind

(** Closed-enum mirror of [Types_core.task_action]. Adding a new action
    upstream forces an arm here. Used for both fingerprinting and the
    Otel_metric_store label. *)
type transition_action =
  | Claim
  | Start
  | Done_action
  | Cancel
  | Release
  | Submit_for_verification
  | Approve_verification
  | Reject_verification
  | Block

(** Closed-enum classification of the [InvalidState] error message.
    Derived from the [Tool_task.validate_transition] surface and the
    other [InvalidState _] emit sites; covers the 16 distinct families
    observed in system_log_2026-05-19. *)
type family =
  | Invalid_transition of
      { from_status : status_kind
      ; action : transition_action
      }
      (** [validate_transition] rejected the [(from_status, action)]
          pair as not in the FSM transition matrix. *)
  | Awaiting_verification_done
      (** Agent tried to mark [AwaitingVerification] task as done
          without going through the verification protocol. *)
  | Self_approval_not_allowed
      (** Verifier and submitter are the same agent on the
          approve path. *)
  | Self_rejection_not_allowed
      (** Verifier and submitter are the same agent on the reject
          path. *)
  | Already_done
      (** Agent retried [Done_action] on a task already in
          [Done] terminal state. *)
  | Active_task_limit_exceeded
      (** Agent already owns more active tasks than the cap allows. *)
  | Submit_verification_missing_evidence
      (** [Submit_for_verification] called without an explicit evidence
          reference. *)
  | Reclaim_policy_blocked
      (** Re-claim blocked because a typed [Block_reclaim] policy was
          explicitly persisted on the task. Free-text handoff notes and
          cycle counts do not produce this family. *)
  | Other_invalid_state
      (** Catch-net for [InvalidState] messages that do not match any
          of the families above. Kept as an explicit constructor —
          not a catch-all match arm — so the [classify] function
          remains exhaustive and the [Other_invalid_state] case is
          visible to operators via the Otel_metric_store label. *)

(** Stable string label for log/metric dimensions. Total. *)
val family_to_string : family -> string

(** All [family] inhabitants, with parametric ones enumerated over the
    Cartesian product of [status_kind × transition_action]. Used by
    exhaustiveness tests. Cardinality is bounded:
    [6 × 9 + 8] = [62]. *)
val all_families : family list

(** [classify msg] inspects the raw [InvalidState] message body
    (the substring after [\[TaskError\] Invalid task state: ]) and
    returns the matching [family]. Uses pattern fragments observed
    in [lib/tool_task.ml] error builders; falls back to
    [Other_invalid_state] only when no fragment matches. *)
val classify : string -> family

(** Carrier for the [`Threshold_silence] outcome. [count] is the
    running failure count when the threshold tripped (>=
    [silence_threshold]); [silence_threshold] echoes the threshold the
    caller observed. *)
type threshold_silence_payload =
  { count : int
  ; silence_threshold : int
  }

(** Classification outcome. The caller is [Tool_task] (the transition
    dispatch); the outcome dictates how the failure logs:

    - [`First] — first time this [(task_id, family)] pair has been
      blocked in this process lifetime. Emit ERROR (preserve existing
      operator-visible signal).

    - [`Repeated count] — same pair has been blocked before; [count]
      is the total failure count including this call (>=2) and is
      strictly less than [silence_threshold]. Demote the log line to
      DEBUG and bump [task_transition_invalid_state_repeated_total].
      The error is still returned to the caller — only the log
      surface changes.

    - [`Threshold_silence payload] — the [silence_threshold] identical
      failures have now been seen for this [(task_id, family)] pair;
      payload echoes [count] and [silence_threshold]. The caller
      should emit a single durable ERROR ("threshold reached,
      silencing log surface") and bump
      [task_transition_invalid_state_threshold_silence_total].
      Subsequent failures for the same pair return [`Repeated] until
      [reset_for_task] is called (typically when the task progresses
      to a valid next state). *)
type record_outcome =
  [ `First
  | `Repeated of int
  | `Threshold_silence of threshold_silence_payload
  ]

(** Default silence threshold — the number of identical
    [(task_id, family)] failures tolerated at ERROR / DEBUG before a
    [`Threshold_silence] outcome fires. Tuned against the production
    sample (7 failures / 10 min, 16 distinct families, ~30 s retry
    cadence): threshold 10 means the operator sees one ERROR line
    plus nine DEBUG-demoted intermediates before the [Threshold_silence]
    ERROR, and any further failures for the same pair are
    [`Repeated] + DEBUG only. *)
val default_silence_threshold : int

(** [record_invalid_state ~task_id ~family ()] registers a failure for
    [(task_id, family)] and returns the classification. The fingerprint
    is [(task_id, family)] — two different agents retrying the same
    invalid transition on the same task collapse into the same bucket
    on purpose: the operator-visible pattern is "task X is stuck in
    family Y", not "this specific agent is retrying".

    The default silence threshold is [default_silence_threshold];
    callers that need a different threshold (e.g. tests) can override
    via [?silence_threshold]. *)
val record_invalid_state
  :  ?silence_threshold:int
  -> task_id:string
  -> family:family
  -> unit
  -> record_outcome

(** [reset_for_task ~task_id] removes all per-task state. Called by
    [Tool_task] when the task progresses to a valid next state
    (successful claim / start / done / cancel / release etc.), so the
    next family of failures on that task starts fresh from
    [`First]. *)
val reset_for_task : task_id:string -> unit

(** Reset all internal state. Test-only entry point — do not call
    from production code. Exposed so unit tests can enforce
    isolation between cases. *)
val reset_for_test : unit -> unit

(** Current number of distinct [(task_id, family)] entries.
    Diagnostic only; never used for control flow. *)
val cardinality : unit -> int

(** [failure_count ~task_id ~family] returns the current failure count
    for the given pair, or [0] when no state exists. Diagnostic /
    introspection only; never used for control flow inside the
    module. *)
val failure_count : task_id:string -> family:family -> int
