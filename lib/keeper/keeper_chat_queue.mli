(** Keeper_chat_queue — thread-safe per-keeper message queue.

    Each keeper owns an in-memory FIFO queue for chat messages that
    arrive while the keeper is already processing a previous message.
    When a stream finishes, the queue is drained automatically.

    Once [configure_persistence] is called from server bootstrap, queue
    mutations are mirrored to a per-keeper durable snapshot and replayed on
    restart. Snapshot rewrite failure aborts the mutation before it is
    acknowledged, keeping in-memory state and durable replay aligned.

    Delivery is at-least-once, not at-most-once: {!lease_batch} moves a
    same-source run out of the live queue into a durably-persisted inflight
    slot instead of deleting it outright. The caller must call {!ack} once a
    reply (or failure marker) has actually been persisted for the batch, or
    {!nack} to return the batch to the head of the queue for retry. A lease
    that is never acked or nacked (process crash, unhandled cancellation)
    survives in the durable snapshot and is requeued the next time
    {!configure_persistence} runs — see its doc comment.

    Queue drain is handled by [Keeper_chat_consumer], started from
    server bootstrap.  The [source] field preserves connector context
    so queued dashboard, Discord, and Slack messages can be projected
    into the same keeper-chat execution path without losing reply
    routing metadata.

    @since 2.145.0 *)

(** {1 Types} *)

type message_source =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }

type queued_message = {
  content : string;
  user_blocks : Keeper_multimodal_input.user_input_block list;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
}

(** A same-source run leased out of the live queue by {!lease_batch}.
    [lease_id] identifies this specific lease for {!ack}/{!nack}; it is
    unrelated to the per-message [receipt_id] {!enqueue} returns. *)
type lease = {
  lease_id : string;
  messages : queued_message list;
}

exception Persistence_failed of string
(** Raised when an enqueue mutation cannot be acknowledged as durable. *)

(** [continuation_channel_of_message_source source] converts queued chat
    provenance into the RFC-0320 continuation-channel type. Dashboard queue
    sources may supply [dashboard_thread_id] from the local AG-UI thread; when
    omitted the dashboard surface is preserved as a single route. *)
val continuation_channel_of_message_source :
  ?dashboard_thread_id:string -> message_source -> Keeper_continuation_channel.t

(** {1 Queue operations} *)

(** [configure_persistence base_path] enables durable per-keeper queue
    snapshots under the runtime keeper directory and loads any non-empty
    snapshots into memory for queue-consumer replay.

    A snapshot recorded while a lease was outstanding (the process crashed or
    was killed between {!lease_batch} and the matching {!ack}/{!nack}) has its
    leased messages requeued ahead of the still-queued messages, and the
    stale lease is dropped: nothing survives as "leased" across a restart,
    so a booted process always starts with every keeper's inflight slot free.
    This is the at-least-once guarantee — a message answered but not yet
    acked when the process died is redelivered and may be answered twice. *)
val configure_persistence : base_path:string -> unit

(** [persistence_configured ()] reports whether durable snapshots are enabled
    in this process. *)
val persistence_configured : unit -> bool

(** [enqueue keeper_name msg] adds [msg] to the tail of [keeper_name]'s
    queue.  Creates the queue lazily if it does not yet exist. Returns a
    freshly minted [receipt_id] correlation token for this specific message
    (not persisted, not required to be unique across process restarts) so a
    caller such as the dashboard busy-ack can echo it back to the sender.
    Raises [Persistence_failed] instead of returning a receipt when the
    snapshot cannot be confirmed durable. *)
val enqueue : keeper_name:string -> queued_message -> string

(** [dequeue keeper_name] removes and returns the head message, or
    [None] if the queue is empty or does not exist. Unlike {!lease_batch}
    this is an immediate, unleased pop — it does not participate in the
    ack/nack lifecycle. *)
val dequeue : keeper_name:string -> queued_message option

(** [same_source a b] is true when two messages share a reply route:
    the dashboard surface, the same Discord channel+user, or the same
    Slack channel+user. Coalescing across different routes would lose
    reply routing. *)
val same_source : message_source -> message_source -> bool

(** [lease_batch keeper_name] leases the head run of messages sharing the
    same source ([same_source]) out of the live queue, preserving FIFO
    order, and durably records the lease so a crash before {!ack}/{!nack}
    redelivers it (see {!configure_persistence}). Stops at the first message
    with a different source so each coalesced turn answers one reply route.

    - [Leased lease] — the run was leased; the caller must eventually call
      {!ack} or {!nack} with [lease.lease_id].
    - [Empty] — the queue is empty or absent.
    - [Already_leased lease_id] — a previous lease for this keeper is
      still outstanding (the caller has not yet acked/nacked it); the queue
      is unchanged. At most one lease is outstanding per keeper at a time.
    - [Persist_failed msg] — the snapshot rewrite failed; the queue is
      unchanged (rolled back before this is returned). *)
val lease_batch :
  keeper_name:string ->
  [ `Leased of lease
  | `Empty
  | `Already_leased of string
  | `Persist_failed of string
  ]

(** [ack keeper_name lease_id] permanently removes a leased batch after its
    reply (or failure marker) has been durably persisted by the caller.
    [`Unknown_lease] when [lease_id] does not match the keeper's current
    outstanding lease (already acked/nacked, or never leased). *)
val ack :
  keeper_name:string ->
  lease_id:string ->
  [ `Acked | `Unknown_lease | `Persist_failed of string ]

(** [nack keeper_name lease_id] returns a leased batch to the head of the
    queue, ahead of any messages that arrived while the lease was
    outstanding, so it is retried on the next {!lease_batch}. [`Unknown_lease]
    when [lease_id] does not match the keeper's current outstanding lease. *)
val nack :
  keeper_name:string ->
  lease_id:string ->
  [ `Requeued | `Unknown_lease | `Persist_failed of string ]

(** [merge_batch batch] coalesces a same-source batch into one message:
    contents joined in arrival order with a blank line, semantic user blocks
    and attachments concatenated, the first message's timestamp (queueing
    latency stays measurable), the shared source. [None] on [[]]; a singleton
    is returned unchanged. *)
val merge_batch : queued_message list -> queued_message option

(** [remove_matching keeper_name msg] removes exactly one message structurally
    equal to [msg] from the head run of [keeper_name]'s still-queued messages
    — the leading same-source messages {!lease_batch} would coalesce into one
    turn. A message already moved into the inflight lease by {!lease_batch}
    is out of scope: it is being answered, not merely queued, so it is not a
    candidate for removal here. Duplicates in the head run leave all but the
    first match in place, and a match past the head-run boundary is not
    removed. Returns [`Not_found] when the queue is empty or absent, or when
    no head-run message matches. On a match the durable snapshot is rewritten
    before the removal is reported [`Removed]; a snapshot rewrite failure
    aborts the removal (queue unchanged) and returns [`Persist_failed msg],
    mirroring the persist-abort contract of {!lease_batch}. Serialized on the
    same per-keeper mutex as {!lease_batch}, so a still-queued message is
    answered by at most one of them. *)
val remove_matching :
  keeper_name:string ->
  queued_message ->
  [ `Removed | `Not_found | `Persist_failed of string ]

(** [length keeper_name] returns the number of still-queued messages — it
    excludes a message currently held by an outstanding lease, which is
    being answered rather than waiting. *)
val length : keeper_name:string -> int

(** [snapshot keeper_name] returns the still-queued messages in FIFO order
    without mutating the queue (excludes an outstanding lease's messages, see
    {!length}). Intended for diagnostic projections that need source
    metadata; consumers must still use {!lease_batch} for delivery. *)
val snapshot : keeper_name:string -> queued_message list

(** [clear keeper_name] empties the still-queued messages. Does not affect an
    outstanding lease — {!ack} or {!nack} it explicitly. *)
val clear : keeper_name:string -> unit

(** [all_keeper_names ()] returns a snapshot list of all keeper names
    that currently have a queue in the registry. *)
val all_keeper_names : unit -> string list

module For_testing : sig
  val reset : unit -> unit
  val fail_next_persist : unit -> unit
  val force_next_sync_debt : unit -> unit
  val fail_next_durability_confirmation : unit -> unit
end
