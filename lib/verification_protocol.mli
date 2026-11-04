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
    persists the request record the completion authority reads.
    The Task FSM caller passes the already-transitioned snapshot whose status
    and handoff it will commit. [claim] contains the current producer evidence;
    the protocol does not merge another handoff into it. Returns
    [Error _] when persistence fails, and when an [artifact:] reference is
    submitted but the producer's keeper meta cannot be read: the snapshot
    cannot know where the producer's sandbox keeps the artifact, and the host
    copy is not it. *)

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
    was already running when this stall joined its batch. *)
type retry_delay =
  | Full_interval of { seconds : float }
  | Shared_timer

(** What the completion authority did with a review that committed no
    verdict, reported by the scheduling owner after it acted.
    [Retry_scheduled] means a retry of this verification is armed;
    [No_retry_armed] means this attempt armed nothing, so the next look
    comes from the producer resubmitting, an operator verdict, or the
    authority's whole-backlog sweep. *)
type stall_disposition =
  | Retry_scheduled of { delay : retry_delay }
  | Original_observation_scheduled of { delay : retry_delay }
  | Original_repair_required
  | No_retry_armed

module For_testing : sig
  val verdict_event_json :
    authority:Masc_domain.completion_authority ->
    task_id:string ->
    verification_id:string ->
    verdict:Masc_domain.completion_verdict ->
    notes:string ->
    timestamp:float ->
    Yojson.Safe.t
end
