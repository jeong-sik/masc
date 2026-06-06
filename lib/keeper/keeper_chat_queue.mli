(** Keeper_chat_queue — thread-safe per-keeper message queue.

    Each keeper owns an in-memory FIFO queue for chat messages that
    arrive while the keeper is already processing a previous message.
    When a stream finishes, the queue is drained automatically.

    The queue is transient (not persisted).  Lost on server restart.

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
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
}

(** {1 Queue operations} *)

(** [enqueue keeper_name msg] adds [msg] to the tail of [keeper_name]'s
    queue.  Creates the queue lazily if it does not yet exist. *)
val enqueue : keeper_name:string -> queued_message -> unit

(** [dequeue keeper_name] removes and returns the head message, or
    [None] if the queue is empty or does not exist. *)
val dequeue : keeper_name:string -> queued_message option

(** [length keeper_name] returns the number of queued messages. *)
val length : keeper_name:string -> int

(** [clear keeper_name] empties the queue. *)
val clear : keeper_name:string -> unit

(** [all_keeper_names ()] returns a snapshot list of all keeper names
    that currently have a queue in the registry. *)
val all_keeper_names : unit -> string list
