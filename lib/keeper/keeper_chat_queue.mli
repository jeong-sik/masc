(** Keeper_chat_queue — thread-safe per-keeper message queue.

    Each keeper owns an in-memory FIFO queue for chat messages that
    arrive while the keeper is already processing a previous message.
    When a stream finishes, the queue is drained automatically.

    The queue is transient (not persisted).  Lost on server restart.

    @since 2.145.0 *)

(** {1 Types} *)

type queued_message = {
  content : string;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
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
