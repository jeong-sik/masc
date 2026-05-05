(** Verification_protocol — task verification FSM transitions
    (submit -> verdict -> close).

    Three lifecycle phases:
    + Submit: worker requests verification ({!create_submit_request}
      / {!notify_submit_for_verification} / {!on_submit_for_verification}).
    + Verdict: verifier approves or rejects ({!record_approve_verification}
      / {!notify_approve_verification} for approve;
      {!record_reject_verification} / {!notify_reject_verification} for
      reject).
    + Close: pending verifications past their TTL transition to
      reject ({!check_timeouts}).

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
  config:Coord.config ->
  task:Masc_domain.task ->
  assignee:string ->
  verification_id:string ->
  evidence_refs:string list ->
  (unit, string) result
(** [create_submit_request ~config ~task ~assignee ~verification_id
      ~evidence_refs] persists a board post for the verification
    request.  Returns [Error _] when board persistence fails or
    the task does not satisfy the contract gap pre-check. *)

val notify_submit_for_verification :
  config:Coord.config ->
  task:Masc_domain.task ->
  assignee:string ->
  verification_id:string ->
  evidence_refs:string list ->
  unit
(** [notify_submit_for_verification ...] emits the
    [masc/verification/requested] SSE event without mutating state.
    Used by callers that have already created the board post via
    {!create_submit_request} but need a separate SSE broadcast. *)

val on_submit_for_verification :
  config:Coord.config ->
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
  config:Coord.config ->
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
  config:Coord.config ->
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

(** {1 Timeout sweep} *)

val check_timeouts : config:Coord.config -> unit
(** [check_timeouts ~config] scans pending verifications and
    emits operator-visible timeout events for any past their TTL. No-op when
    [Env_config_runtime.Verification.fsm_enabled ()] is [false]
    — pinned at the contract seam so disabling the FSM does not
    silently drop the timeout sweep entirely; it just does nothing. *)
