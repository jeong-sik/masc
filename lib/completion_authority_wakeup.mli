(** Durable delivery after a completion authority (system LLM or HITL) rejects
    submitted evidence. A live wake is only an acceleration hint; the typed
    rejection is committed to the producer Keeper's queue first. The producer
    is resolved by {!Keeper_producer_route}: a live registry entry, then a
    Keeper meta file at the producer's name. A producer with neither is
    {!Keeper_task_outcome_wake.Unroutable_producer} — no Keeper queue exists
    for it — while a meta file this binary cannot decode is
    {!Keeper_task_outcome_wake.Producer_identity_lookup_failed}. *)

type rejection_outcome =
  | Delivery of Keeper_task_outcome_wake.delivery
      (** How the delivery to the producer Keeper ended; the approval path
          ends in the same outcomes. *)
  | Rejection_superseded of { task_id : string; verification_id : string }
      (** The rejection is no longer the pending one; nothing was written. *)

val wake_rejected_producer :
  config:Workspace_utils_backend_setup.config ->
  producer:string ->
  task_id:string ->
  verification_id:string ->
  reason:string ->
  authority:Masc_domain.completion_authority ->
  rejection_outcome
(** Publishes only a still-pending current rejection. The Keeper intake lock
    precedes the backlog lock and lease fence. Queue observers and the live
    wake run after both locks are released. Already delivered or superseded
    identities produce [Rejection_superseded] without a queue write. *)

val release_unroutable_task :
  config:Workspace_utils_backend_setup.config ->
  Masc_domain.pending_completion_rejection ->
  ( [ `Superseded
    | `Release_refused
    | `Released of string * int
    ],
    string )
  result
(** The step {!reconcile_pending} takes after {!wake_rejected_producer}
    answered {!Keeper_task_outcome_wake.Unroutable_producer}: return the Task
    to the backlog, asking
    the route again inside the backlog lock. [Error] is the answer
    {!reconcile_pending} retains for the next interval: a Keeper queue or an
    undecodable Keeper meta appeared at the producer's name before the lock,
    or the release failed and can succeed later. *)

type recovery_report = { delivered : int; unroutable : int; retained : int }
(** [delivered] counts obligations queued (or signaled live) and acknowledged,
    not receipts confirmed by the producer: a live wake may still have failed
    above it, and the durable queue carries the obligation then. *)

val reconcile_pending :
  config:Workspace_utils_backend_setup.config -> (recovery_report, string) result
(** Deliver both rejection and approval obligations from the authoritative backlog.
    Approval delivery never changes the completed Task back to an active state.
    A durable Keeper queue write precedes exact-key source acknowledgment.
    Identity lookup, queue and acknowledgement failures retain the obligation
    for the next recovery. An {!Keeper_task_outcome_wake.Unroutable_producer}
    returns the Task to the
    backlog and is then acknowledged and counted in [unroutable]: retrying
    cannot create a Keeper queue, and a Task whose producer will never act
    again has to be claimable by someone else. The route is read once more
    inside the backlog lock, so a Keeper queue that appears between the two
    keeps the obligation instead of losing it to a release. A release that
    fails is kept unless it both cannot succeed on a later interval and can
    still be acknowledged — acknowledging takes the same backlog write the
    release just failed at, so a backlog that cannot be written leaves keeping
    it as the only option. An obligation carrying an unusable task id or
    authority ends there rather than becoming the permanent retry this path
    was built to remove. The verdict's reason travels on the handoff context;
    typed verdict, rejection and delivery records carry the verification id.
    Delivery is at
    least once across the queue-write/source-ack crash window; the
    verification-keyed stimulus is information, not permission to mutate. *)
