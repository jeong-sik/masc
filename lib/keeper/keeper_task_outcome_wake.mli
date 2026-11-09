(** Keeper_task_outcome_wake — tell the producer Keeper that the completion
    authority approved its submitted evidence.

    The approval twin of [Completion_authority_wakeup]. A rejection has always
    reached the producer as a typed stimulus; an approval used to end the
    loop in silence: the Board receipt is Unlisted ("approval wakes nobody")
    and the producer's current-task projection was cleared at submission, so
    the producer learned its task closed only when some later cycle noticed.
    (#25868.)

    The payload is pointer-only — the verdict record and the Board receipt
    stay the content stores — and the stimulus is committed through the same
    fail-closed durable path the delegation answer and the rejection use, so
    a failed write is reported rather than swallowed. The live wake that
    follows is a hint: it only reaches a [Running] Keeper, and its failure is
    logged, because the committed stimulus is already in the queue the Keeper
    drains on its next admitted turn.

    [delivery] and the two steps around the queue write, [producer_keeper]
    and [wake_producer_keeper], are the ones [Completion_authority_wakeup]
    uses for a rejection: it ends in one of these outcomes, or in its own
    [Rejection_superseded] when the rejection is no longer the pending one. *)

type delivery =
  | Signaled of { keeper_name : string }
  | Durable_deferred of {
      keeper_name : string;
      wakeup : Keeper_registry.wakeup_outcome;
    }
  | Durable_wake_failed of { keeper_name : string; detail : string }
  | Unroutable_producer of { producer : string; task_id : string }
  | Producer_identity_lookup_failed of {
      producer : string;
      task_id : string;
      detail : string;
    }
  | Durable_queue_failed of { keeper_name : string; detail : string }

val producer_keeper :
  config:Workspace_utils_backend_setup.config ->
  producer:string ->
  task_id:string ->
  (string, delivery) result
(** The Keeper whose durable queue receives a verdict about [task_id],
    resolved by {!Keeper_producer_route}. [Error] is the delivery that ends the
    attempt before any queue write: [Unroutable_producer] when no Keeper
    carries the producer's name, [Producer_identity_lookup_failed] when a meta
    file sits at the name but this binary cannot read it. *)

val wake_producer_keeper :
  notify:(unit -> unit) ->
  config:Workspace_utils_backend_setup.config ->
  keeper_name:string ->
  delivery
(** The live wake that follows a committed verdict stimulus. [notify] runs
    first inside the same guard, so an exception it raises becomes
    [Durable_wake_failed] like one from the wake itself; Eio cancellation is
    re-raised. A Keeper that is not [Running] answers [Durable_deferred]. *)

val wake_approved_producer :
  config:Workspace_utils_backend_setup.config ->
  producer:string ->
  task_id:string ->
  verification_id:string ->
  authority:Masc_domain.completion_authority ->
  delivery
(** Commit the typed approval stimulus to the producer's durable queue and
    then attempt a live wake. The producer is resolved by
    {!Keeper_producer_route}, as for a rejection: a live registry entry, then
    a Keeper meta file at the producer's name. Neither is
    [Unroutable_producer]; a meta file this binary cannot decode is
    [Producer_identity_lookup_failed]. Both are logged by the caller, not
    dropped silently. *)
