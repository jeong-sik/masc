(** Durable delivery after a completion authority (system LLM or HITL) rejects
    submitted evidence. A live wake is only an acceleration hint; the typed
    rejection is committed to the producer Keeper's queue first. The producer
    is resolved by {!Keeper_producer_route}: a live registry entry, then a
    Keeper meta file at the producer's name. A producer with neither is
    {!Unroutable_producer} — no Keeper queue exists for it — while a meta file
    this binary cannot decode is {!Producer_identity_lookup_failed}. *)

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

val wake_rejected_producer :
  config:Workspace_utils_backend_setup.config ->
  producer:string ->
  task_id:string ->
  verification_id:string ->
  reason:string ->
  authority:Masc_domain.completion_authority ->
  delivery


type recovery_report = { delivered : int; unroutable : int; retained : int }

val reconcile_pending :
  config:Workspace_utils_backend_setup.config -> (recovery_report, string) result
(** Deliver verdict-committed repair obligations from the authoritative backlog.
    A durable Keeper queue write precedes exact-key source acknowledgment.
    Identity lookup, queue and acknowledgement failures retain the obligation
    for the next recovery. An {!Unroutable_producer} is acknowledged and
    counted in [unroutable]: retrying cannot create a Keeper queue, and the
    verdict with its reason is already committed on the Task. Delivery is at
    least once across the queue-write/source-ack crash window; the
    verification-keyed stimulus is information, not permission to mutate. *)
