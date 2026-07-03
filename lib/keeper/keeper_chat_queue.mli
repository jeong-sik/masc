(** Keeper_chat_queue — thread-safe per-keeper message queue.

    Each keeper owns an in-memory FIFO queue for chat messages that
    arrive while the keeper is already processing a previous message.
    When a stream finishes, the queue is drained automatically.

    Once [configure_persistence] is called from server bootstrap, queue
    mutations are mirrored to a per-keeper durable snapshot and replayed on
    restart. Snapshot rewrite failure aborts the mutation before a dequeued
    message is acknowledged, keeping in-memory state and durable replay aligned.

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

(** {1 Queue operations} *)

(** [configure_persistence base_path] enables durable per-keeper queue
    snapshots under the runtime keeper directory and loads any non-empty
    snapshots into memory for queue-consumer replay. *)
val configure_persistence : base_path:string -> unit

(** [persistence_configured ()] reports whether durable snapshots are enabled
    in this process. *)
val persistence_configured : unit -> bool

(** [enqueue keeper_name msg] adds [msg] to the tail of [keeper_name]'s
    queue.  Creates the queue lazily if it does not yet exist. *)
val enqueue : keeper_name:string -> queued_message -> unit

(** [dequeue keeper_name] removes and returns the head message, or
    [None] if the queue is empty or does not exist. *)
val dequeue : keeper_name:string -> queued_message option

(** [same_source a b] is true when two messages share a reply route:
    the dashboard surface, the same Discord channel+user, or the same
    Slack channel+user. Coalescing across different routes would lose
    reply routing. *)
val same_source : message_source -> message_source -> bool

(** [dequeue_batch keeper_name] removes and returns the head run of
    messages sharing the same source ([same_source]), preserving FIFO
    order. Stops at the first message with a different source so each
    coalesced turn answers one reply route. Returns [[]] when the queue
    is empty or absent. *)
val dequeue_batch : keeper_name:string -> queued_message list

(** [merge_batch batch] coalesces a same-source batch into one message:
    contents joined in arrival order with a blank line, semantic user blocks
    and attachments concatenated, the first message's timestamp (queueing
    latency stays measurable), the shared source. [None] on [[]]; a singleton
    is returned unchanged. *)
val merge_batch : queued_message list -> queued_message option

(** [remove_matching keeper_name msg] removes exactly one message structurally
    equal to [msg] from the head run of [keeper_name]'s queue — the leading
    same-source messages [dequeue_batch] coalesces into one turn. Duplicates in
    the head run leave all but the first match in place, and a match past the
    head-run boundary is not removed. Returns [`Not_found] when the queue is
    empty or absent, or when no head-run message matches. On a match the durable
    snapshot is rewritten before the removal is reported [`Removed]; a snapshot
    rewrite failure aborts the removal (queue unchanged) and returns
    [`Persist_failed msg], mirroring the persist-abort contract of
    {!dequeue_batch}. Serialized on the same per-keeper mutex as
    {!dequeue_batch}, so a queued message is answered by at most one of them. *)
val remove_matching :
  keeper_name:string ->
  queued_message ->
  [ `Removed | `Not_found | `Persist_failed of string ]

(** [length keeper_name] returns the number of queued messages. *)
val length : keeper_name:string -> int

(** [clear keeper_name] empties the queue. *)
val clear : keeper_name:string -> unit

(** [all_keeper_names ()] returns a snapshot list of all keeper names
    that currently have a queue in the registry. *)
val all_keeper_names : unit -> string list

module For_testing : sig
  val reset : unit -> unit
  val fail_next_persist : unit -> unit
end
