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

(** Drain stimuli intended for board reactivity. [window_sec] caps the
    age of stimuli returned to the caller. *)
val drain_board :
  ?window_sec:float -> base_path:string -> string
  -> Keeper_event_queue.stimulus list
