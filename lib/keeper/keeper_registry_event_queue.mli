(** Per-keeper event-queue access.

    SSOT for enqueueing / draining the per-keeper stimulus queue.
    Internal CAS retry on the entry-owned
    [event_queue : Keeper_event_queue.t Atomic.t] field; no central
    registry Atomic touched. *)

(** Enqueue a stimulus on the keeper's event queue.
    Logs a warning when the keeper is not registered. *)
val enqueue : base_path:string -> string -> Keeper_event_queue.stimulus -> unit

(** Read-only snapshot of the keeper's queue. Returns
    [Keeper_event_queue.empty] when the keeper is unregistered. *)
val snapshot : base_path:string -> string -> Keeper_event_queue.t

(** Remove and return the head stimulus, or [None] when the queue is
    empty or the keeper is unregistered. *)
val dequeue : base_path:string -> string -> Keeper_event_queue.stimulus option

(** Drain stimuli intended for board reactivity. [window_sec] caps the
    age of stimuli returned to the caller. *)
val drain_board :
  ?window_sec:float -> base_path:string -> string
  -> Keeper_event_queue.stimulus list
