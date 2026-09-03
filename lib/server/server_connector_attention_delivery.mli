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
  unit
(** Enqueue the [Connector_attention] stimulus for [event_id], then signal the
    Keeper. The wake is a hint: a busy or lifecycle-deferred Keeper still finds
    the entry on its next lane cycle.

    The attention row and the queue entry are two separate writes. When the
    queue refuses the entry there is nothing left to make any Keeper judge the
    row -- the wake is edge-triggered, and only a new ambient message re-arms
    it -- so the row would sit pending on the operator's attention panel
    forever, wearing the face of work that is coming. It is marked
    [Quarantined] instead: nobody judged it, and nobody will. *)
