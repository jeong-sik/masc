(** Per-keeper event-queue access.

    SSOT for enqueueing / draining the per-keeper stimulus queue.
    Internal CAS retry on the entry-owned
    [event_queue : Keeper_event_queue.t Atomic.t] field; no central
    registry Atomic touched. Successful mutations are mirrored to the
    MASC-owned durable queue snapshot so a keeper restart can replay
    pending stimuli. *)

(** Successful enqueue delivery class. [`Queued] means a registered keeper's
    live queue was updated and the live snapshot was durably persisted.
    [`Persisted] means no registered keeper was present, but the durable replay
    snapshot was updated. [`Duplicate] means the stimulus identity was already
    present and the current live/durable snapshot was still successfully
    persisted. *)
type enqueue_success =
  [ `Queued
  | `Persisted
  | `Duplicate
  ]

val enqueue_result :
  base_path:string -> string -> Keeper_event_queue.stimulus -> (enqueue_success, string) result
(** Result-returning enqueue. Returns [Error _] when the durable snapshot write
    fails, so wake producers do not count or wake a stimulus as delivered when
    the Event Layer cannot preserve replay state. *)

(** Compatibility wrapper around {!enqueue_result}. Failures are logged and
    discarded to preserve legacy [unit] callers. Producers that need to know
    whether delivery was durable must use {!enqueue_result}. *)
val enqueue : base_path:string -> string -> Keeper_event_queue.stimulus -> unit

(** Read-only snapshot of the keeper's queue. If the keeper is not registered,
    read the durable snapshot so diagnostics still expose pending replay. *)
val snapshot : base_path:string -> string -> Keeper_event_queue.t

(** Remove and return the head stimulus, or [None] when the queue is
    empty or the keeper is unregistered. *)
val dequeue : base_path:string -> string -> Keeper_event_queue.stimulus option
(** Compatibility wrapper around {!dequeue_result}. Persistence failures are
    logged and return [None] so callers do not process a stimulus whose
    durable transition could not be completed. *)

val dequeue_result :
  base_path:string -> string -> (Keeper_event_queue.stimulus option, string) result
(** Remove and return the head stimulus only after its durable in-flight lease
    is recorded and its pending snapshot is updated. Returns [Error _] when the
    durable transition cannot be completed. *)

(** Put previously drained stimuli back at the front of the queue. This is a
    crash-recovery primitive: if the keepalive cycle dies after dequeue/drain
    but before the turn completes, the stimuli must remain replayable. The
    compatibility wrapper logs and discards durable transition failures; use
    {!requeue_front_result} when the caller must branch on that failure. *)
val requeue_front : base_path:string -> string -> Keeper_event_queue.stimulus list -> unit

val requeue_front_result :
  base_path:string -> string -> Keeper_event_queue.stimulus list -> (unit, string) result
(** Result-returning variant of {!requeue_front}. Returns [Error _] when the
    durable pending/in-flight transition cannot be completed. *)

val ack_consumed :
  base_path:string -> string -> Keeper_event_queue.stimulus list -> unit
(** Acknowledge consumed stimuli after a keepalive turn completes. Until this
    runs, a restart reloads the leased stimuli for at-least-once replay. A
    successful acknowledgement also appends a reaction-ledger
    [Stimulus_consumed] receipt for each consumed stimulus. *)

val drop_by_post_id :
  base_path:string
  -> string
  -> post_id:string
  -> (Keeper_event_queue.stimulus list, string) result
(** Remove matching stimuli from the live queue plus durable pending/in-flight
    snapshots, returning the exact stimuli that were dropped. Returns [Error _]
    when durable removal fails so callers do not clear recovery state while a
    replayable stimulus remains on disk. *)

(** Drain stimuli intended for board reactivity. [window_sec] caps the
    age of stimuli returned to the caller. *)
val drain_board :
  ?window_sec:float -> base_path:string -> string
  -> Keeper_event_queue.stimulus list

val drain_board_result :
  ?window_sec:float ->
  base_path:string ->
  string ->
  (Keeper_event_queue.stimulus list, string) result
(** Result-returning variant of {!drain_board}. Board stimuli are returned only
    after their in-flight lease is durable and their pending snapshot is
    updated. *)
