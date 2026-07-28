(** Verification_protocol -- immutable verification submission plus
    notifications for committed Task FSM transitions. The request stores only
    submit-time evidence; Task status owns verifier assignment and outcome. *)

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
    request.  Returns [Error _] when
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
    {!create_submit_request} but need a separate SSE broadcast. *)

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

(** {1 Task verdict notifications} *)

val notify_approve_verification :
  task_id:string ->
  verifier:string ->
  verification_id:string ->
  notes:string ->
  unit
(** [notify_approve_verification ...] emits the SSE
    [masc/verification/verdict] event with [type=approved].
    State-free — no FSM mutation, no journal write. *)

val notify_reject_verification :
  task_id:string ->
  verifier:string ->
  verification_id:string ->
  reason:string ->
  unit
(** [notify_reject_verification ...] emits the SSE
    [masc/verification/verdict] event with [type=rejected].
    State-free. *)
