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
    persistence fails, and when an [artifact:] reference is submitted but the
    producer's keeper meta cannot be read: the snapshot cannot know where the
    producer's sandbox keeps the artifact, and the host copy is not it. *)

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

(** How soon an armed retry fires. [Full_interval] is a timer this stall
    armed itself: it fires after [seconds]. [Shared_timer] is a timer that
    was already running when this stall joined its batch; the post names no
    number it does not hold. *)
type retry_delay =
  | Full_interval of { seconds : float }
  | Shared_timer

(** What the completion authority did with a review that committed no
    verdict, reported by the scheduling owner after it acted.
    [Retry_scheduled] means a retry of this verification is armed;
    [No_retry_armed] means this attempt armed nothing, so the next look
    comes from the producer resubmitting, an operator verdict, or the
    authority's whole-backlog sweep. The Board sentence is rendered from
    this value, so the post cannot describe a timer the lane did not arm. *)
type stall_disposition =
  | Retry_scheduled of { delay : retry_delay }
  | No_retry_armed

(** Which review stopped. A Task review is keyed by its verification id and
    carries what its scheduling owner did about a retry; a Goal review is
    keyed by the durable request it answers and carries no disposition,
    because the Goal verifier arms no retry — its post always reads as
    [No_retry_armed]. Both stops are the same event — a verifier ended a
    review without a verdict — so both go through
    {!notify_stalled_verification} and share its channel, metadata and
    repeat rule. *)
type stalled_subject =
  | Task_review of
      { task_id : string
      ; verification_id : string
      ; disposition : stall_disposition
      }
  | Goal_review of { goal_id : string; request_id : string }

val notify_stalled_verification :
  authority:Masc_domain.completion_authority ->
  subject:stalled_subject ->
  gate:string ->
  detail:string ->
  unit
(** Board projection for every review that stopped without a verdict —
    for a Task: [Not_reviewed], [Infrastructure_unavailable],
    [Commit_failed], [Raised]; for a Goal: every deferral of a request that
    still stands — whether or not a retry is armed: without this post the
    only surface is the bounded run registry and the subject waits
    invisibly. The post names the subject, its request, the gate, and what
    happens next. Under [Retry_scheduled] it says a retry is armed and how
    soon. Under [No_retry_armed] a Task post names the two forward paths
    that exist today — the assignee resubmitting through
    [submit_for_verification] (a legal transition from
    [AwaitingVerification] that supersedes this verification), or an
    operator HITL verdict — and the sweep that reviews it again without
    either; a Goal post names a Keeper calling [request_complete] on the
    Goal. A Task caller passes, inside [Task_review], the disposition the
    scheduling owner reported after it acted, so the post follows the
    timer, never the other way round.

    One post per disposition change: for a (subject, gate) the notice
    compares against the disposition of the latest post on the Board
    (chronological by [created_at]) and posts only when that differs or no
    post decodes. The subject is compared by its identity fields —
    [task_id]/[verification_id] or [goal_id]/[request_id]. [detail] travels
    as evidence and is not part of the comparison. Visibility only: the
    post schedules nothing and gates nothing. A board write that returns an
    error is logged here and does not affect the review outcome; an
    exception out of the Board is the caller's to contain. *)

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
    subject:stalled_subject ->
    gate:string ->
    detail:string ->
    string

  val stalled_metadata :
    authority:Masc_domain.completion_authority ->
    subject:stalled_subject ->
    gate:string ->
    detail:string ->
    Yojson.Safe.t

  val stall_disposition_of_json : Yojson.Safe.t -> stall_disposition option
  (** The strict inverse of the [disposition] field [stalled_metadata]
      writes: [None] for any shape the encoder does not produce. *)
end
