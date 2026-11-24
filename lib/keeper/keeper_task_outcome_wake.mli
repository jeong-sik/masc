(** Queue the completion authority's verdict for its producer. The typed wake
    policy chooses when a committed verdict may start a turn. *)

type delivery =
  | Queued_for_later of { keeper_name : string }
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
  wake_policy:Keeper_keepalive_signal.stimulus_wake_policy ->
  notify:(unit -> unit) ->
  config:Workspace_utils_backend_setup.config ->
  keeper_name:string ->
  delivery
(** Publish the queue change, then apply the producer's selected timing.
    A carried verdict stays pending. A tick registers the next boundary. *)

val wake_approved_producer :
  config:Workspace_utils_backend_setup.config ->
  producer:string ->
  task_id:string ->
  verification_id:string ->
  authority:Masc_domain.completion_authority ->
  delivery
(** Commit the approval and apply its timing. When carried, the Keeper reads
    it on its next eligible turn. *)
