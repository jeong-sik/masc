(** Fresh direct messages may share one invocation only when their typed actor,
    reply destination and per-turn instructions agree. The normal queue batches
    only a contiguous compatible prefix, so another conversation remains ahead
    of messages admitted after it. The store excludes continuations. *)
val select : Keeper_chat_operation_store.batch_selector

(** Interactive admission explicitly moves the compatible cohort ahead of
    other queued conversations. It may select across an incompatible row before
    the store atomically reorders that row behind the cohort. *)
val select_priority : Keeper_chat_operation_store.batch_selector

val event_for_member : operation_id:Keeper_chat_operation.Operation_id.t ->
  Keeper_chat_events.keeper_chat_event -> Keeper_chat_events.keeper_chat_event
(** One shared computation, separate request-bound live/replay event identities. *)
