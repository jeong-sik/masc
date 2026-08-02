(** Durable delivery after a completion authority (system LLM or HITL) rejects
    submitted evidence. A live wake is only an acceleration hint; the typed
    rejection is committed to the producer Keeper's queue first. *)

type delivery =
  | Signaled of { keeper_name : string }
  | Durable_deferred of {
      keeper_name : string;
      wakeup : Keeper_registry.wakeup_outcome;
    }
  | Durable_wake_failed of { keeper_name : string; detail : string }
  | Unroutable_producer of { producer : string; task_id : string }
  | Durable_queue_failed of { keeper_name : string; detail : string }

val wake_rejected_producer :
  config:Workspace_utils_backend_setup.config ->
  producer:string ->
  task_id:string ->
  verification_id:string ->
  reason:string ->
  authority:Masc_domain.completion_authority ->
  delivery
