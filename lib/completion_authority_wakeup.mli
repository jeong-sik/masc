(** Durable delivery after a completion authority (system LLM or HITL) rejects
    submitted evidence. A live wake is only an acceleration hint; the typed
    rejection is committed to the producer Keeper's queue first. When a live
    registry entry exists, its exact [agent_name] binding is authoritative. A
    stopped producer is resolved from the same [agent_name] field in persisted
    Keeper metadata; an absent or ambiguous binding remains an explicit typed
    delivery failure. *)

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


type recovery_report = { delivered : int; retained : int }

val reconcile_pending :
  config:Workspace_utils_backend_setup.config -> (recovery_report, string) result
(** Deliver verdict-committed repair obligations from the authoritative backlog.
    A durable Keeper queue write precedes exact-key source acknowledgment.
    Identity/queue/ack failures retain the obligation for the next recovery.
    Delivery is at least once across the queue-write/source-ack crash window;
    the verification-keyed stimulus is information, not permission to mutate. *)
