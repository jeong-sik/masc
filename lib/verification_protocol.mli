(** Verification_protocol -- immutable verification submission plus
    notifications for committed Task FSM transitions. The request stores only
    submit-time evidence; Task status owns the pending obligation and outcome. *)

(** {1 Submit phase} *)

val create_submit_request :
  config:Workspace.config ->
  task:Masc_domain.task ->
  assignee:string ->
  verification_id:string ->
  claim:Masc_domain.verification_claim ->
  (unit, string) result
(** [create_submit_request ~config ~task ~assignee ~verification_id ~claim]
    persists the request record the completion authority reads. For a
    cancellation the record keeps no copy of the producer's reason: the
    operator reads it from the Board post
    {!notify_submit_for_verification} makes. Returns [Error _] when
    persistence fails. *)

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
  claim:Masc_domain.verification_claim ->
  unit
(** [notify_submit_for_verification ...] emits the
    [masc/verification/requested] SSE event without mutating state.
    Used by callers that have already created the board post via
    {!create_submit_request} but need a separate SSE broadcast. *)

(** {1 Task verdict notifications} *)

val notify_approve_verification :
  task_id:string ->
  authority:Masc_domain.completion_authority ->
  verification_id:string ->
  notes:string ->
  unit
(** [notify_approve_verification ...] emits the SSE
    [masc/verification/verdict] event with [verdict=approved]. The [type]
    field carries the event name, and [authority_kind]/[authority_actor]
    carry typed provenance.
    State-free — no FSM mutation, no journal write. *)

val notify_reject_verification :
  task_id:string ->
  authority:Masc_domain.completion_authority ->
  verification_id:string ->
  reason:string ->
  unit
(** [notify_reject_verification ...] emits the SSE
    [masc/verification/rejected] event with [verdict=rejected]. The [type]
    field carries the event name, and [authority_kind]/[authority_actor]
    carry typed provenance.
    State-free. *)

val notify_stalled_verification :
  authority:Masc_domain.completion_authority ->
  task_id:string ->
  verification_id:string ->
  gate:string ->
  detail:string ->
  unit
(** Board projection for every review that completed [Not_reviewed]: no
    verdict was committed and the authority schedules no further attempt, so
    without this post the only surface is the bounded run registry and the
    task waits invisibly. The post names the task, the
    verification id, the gate, and the two forward paths that exist today —
    the assignee resubmitting through [submit_for_verification] (a legal
    transition from [AwaitingVerification] that supersedes this
    verification), or an operator HITL verdict. Visibility only: no
    scheduling state, no retry obligation. A board write failure is logged
    and does not affect the review outcome. *)

module For_testing : sig
  val verdict_event_json :
    authority:Masc_domain.completion_authority ->
    task_id:string ->
    verification_id:string ->
    verdict:Masc_domain.completion_verdict ->
    notes:string ->
    timestamp:float ->
    Yojson.Safe.t

  val stalled_board_content :
    task_id:string -> verification_id:string -> gate:string -> detail:string -> string

  val stalled_metadata :
    authority:Masc_domain.completion_authority ->
    task_id:string ->
    verification_id:string ->
    gate:string ->
    detail:string ->
    Yojson.Safe.t
end
