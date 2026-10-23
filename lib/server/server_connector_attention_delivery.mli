(** Durable delivery of one connector attention row into a Keeper's queue.

    Discord and Slack accept an ambient message the same way: the
    external-attention row is recorded first, then the queue entry that makes a
    Keeper judge it. Only the channel coordinates differ, so both gateways
    deliver through here. *)

val deliver :
  base_path:string ->
  keeper_name:string ->
  event_id:string ->
  channel:Keeper_continuation_channel.t ->
  (unit, string) result
(** Durably enqueue the original [Connector_attention] stimulus once, including
    after consumption or lost producer ACK, then signal the
    Keeper. The wake is a hint: a busy or lifecycle-deferred Keeper still finds
    the entry on its next lane cycle.

    A refused entry is logged, counted and returned as [Error]: the
    queue is what says a Keeper owes an answer, so an entry that never landed
    leaves nothing behind claiming otherwise. *)
