(** Verification_protocol — task verification FSM transitions
    (submit -> verdict).

    Two lifecycle phases:
    + Submit: worker requests verification ({!create_submit_request}
      / {!notify_submit_for_verification} / {!on_submit_for_verification}).
    + Verdict: verifier approves or rejects ({!record_approve_verification}
      / {!notify_approve_verification} for approve;
      {!record_reject_verification} / {!notify_reject_verification} for
      reject).

    There is no timeout close phase: RFC-0220 removed the destructive
    wall-clock deadline (an AwaitingVerification obligation stays claimable
    by a verifier; long waits surface from the activity-event stream).

    {b record_* vs notify_* split}: \[record_*\] mutates state
    (Verification.ml FSM + journal entries); \[notify_*\] emits SSE
    events for dashboards.  Separated so admin overrides can call
    one without the other (e.g. silent re-issue without dashboard
    SSE noise).

    Internal: \[submit_request_spec\] (type + builder),
    \[first_line\] (text helper), \[deliverable_claims_completion\],
    \[warn_contract_gap\], \[on_approve_verification\],
    \[on_reject_verification\] (no external callers). *)

(** {1 Submit phase} *)

val create_submit_request :
  config:Workspace.config ->
  task:Masc_domain.task ->
  assignee:string ->
  verification_id:string ->
  evidence_refs:string list ->
  (unit, string) result
(** [create_submit_request ~config ~task ~assignee ~verification_id
      ~evidence_refs] persists a board post for the verification
    request.  The persisted request output includes the latest
    task-scoped [cdal_verdict] when one exists, or [null] when the
    ledger has no verdict for the task.  Returns [Error _] when
    board persistence fails or the task does not satisfy the
    contract gap pre-check. *)

val delete_verification_request :
  config:Workspace.config ->
  verification_id:string ->
  (unit, string) result
(** RFC-0221 §3.1 compensation: remove the verification record for
    [verification_id] when its task_status commit did not land, so the two
    stores never disagree. A missing record is success (idempotent). *)

val notify_submit_for_verification :
  config:Workspace.config ->
  task:Masc_domain.task ->
  assignee:string ->
  verification_id:string ->
  evidence_refs:string list ->
  unit
(** [notify_submit_for_verification ...] emits the
    [masc/verification/requested] SSE event without mutating state.
    Used by callers that have already created the board post via
    {!create_submit_request} but need a separate SSE broadcast.
    The board meta and SSE payload mirror the [cdal_verdict] field
    from the persisted request output. *)

val on_submit_for_verification :
  config:Workspace.config ->
  task:Masc_domain.task ->
  assignee:string ->
  verification_id:string ->
  evidence_refs:string list ->
  (unit, string) result
(** [on_submit_for_verification ...] is the combined wrapper:
    {!create_submit_request} + {!notify_submit_for_verification}.
    Returns the result of the persist step; SSE notify runs only
    on success. *)

(** {1 Approve verdict} *)

val record_approve_verification :
  config:Workspace.config ->
  task_id:string ->
  verifier:string ->
  verification_id:string ->
  notes:string ->
  (unit, string) result
(** [record_approve_verification ...] mutates the verification FSM
    to [Pending -> Completed Pass] and persists the verdict
    journal entry.  Required: non-empty [verification_id]; an
    empty value returns an error message about the missing id. *)

val notify_approve_verification :
  task_id:string ->
  verifier:string ->
  verification_id:string ->
  notes:string ->
  unit
(** [notify_approve_verification ...] emits the SSE
    [masc/verification/verdict] event with [type=approved].
    State-free — no FSM mutation, no journal write. *)

(** {1 Reject verdict} *)

val record_reject_verification :
  config:Workspace.config ->
  task_id:string ->
  verifier:string ->
  verification_id:string ->
  reason:string ->
  (unit, string) result
(** [record_reject_verification ...] mutates the FSM to
    [Pending -> Completed Fail] and persists the verdict journal
    entry.  Same [verification_id] requirement as approve. *)

val notify_reject_verification :
  task_id:string ->
  verifier:string ->
  verification_id:string ->
  reason:string ->
  unit
(** [notify_reject_verification ...] emits the SSE
    [masc/verification/verdict] event with [type=rejected].
    State-free. *)
