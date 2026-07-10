(** Per-keeper event-queue access.

    SSOT for enqueueing / draining the per-keeper stimulus queue.
    Internal CAS retry on the entry-owned
    [event_queue : Keeper_event_queue.t Atomic.t] field; no central
    registry Atomic touched. Successful mutations are mirrored to the
    MASC-owned durable queue snapshot so a keeper restart can replay
    pending stimuli. *)

(** Enqueue a stimulus on the keeper's event queue. When the keeper is not
    registered yet, persist the stimulus to the durable snapshot so later
    registration can replay it instead of dropping the wake at the
    restart/register boundary. *)
val enqueue : base_path:string -> string -> Keeper_event_queue.stimulus -> unit

(** Read-only snapshot of the keeper's queue. If the keeper is not registered,
    read the durable snapshot so diagnostics still expose pending replay. *)
val snapshot : base_path:string -> string -> Keeper_event_queue.t

(** Remove and return the head stimulus, or [None] when the queue is
    empty or the keeper is unregistered. *)
val dequeue : base_path:string -> string -> Keeper_event_queue.stimulus option

(** Put previously drained stimuli back at the front of the queue. This is a
    crash-recovery primitive: if the keepalive cycle dies after dequeue/drain
    but before the turn completes, the stimuli must remain replayable. *)
val requeue_front : base_path:string -> string -> Keeper_event_queue.stimulus list -> unit

val ack_consumed :
  base_path:string -> string -> Keeper_event_queue.stimulus list -> unit
(** Acknowledge consumed stimuli after a keepalive turn completes. Until this
    runs, a restart reloads the leased stimuli for at-least-once replay. *)

val ack_consumed_result :
  base_path:string -> string -> Keeper_event_queue.stimulus list -> (unit, string) result
(** Result-returning variant of {!ack_consumed}. Callers that publish follow-on
    evidence must use this so they do not claim an acknowledgement after durable
    queue persistence failed. *)

val drop_by_post_id :
  base_path:string
  -> string
  -> post_id:string
  -> (Keeper_event_queue.stimulus list, string) result
(** Remove matching stimuli from the live queue plus durable pending/in-flight
    snapshots, returning the exact stimuli that were dropped. Returns [Error _]
    when durable removal fails so callers do not clear recovery state while a
    replayable stimulus remains on disk. *)

(** Drain every queued board-signal stimulus for the keeper (RFC-0334 W2:
    turn-keyed digest — one turn consumes everything queued since the
    keeper's last turn, however it arrived). *)
val drain_board :
  base_path:string -> string
  -> Keeper_event_queue.stimulus list
