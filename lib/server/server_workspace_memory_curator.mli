(** One serialized Addon-backed Curator owner per physical workspace. *)
val start : sw:Eio.Switch.t -> config:Workspace.config -> unit
(** Discover/recover original work before new capture. Existing accepted local
    settlement survives Off; new roots and successors use fresh configured
    Runtime authority. Classification and Briefing keep separate durable
    boundaries. Pending observer receipts are conditionally delivered and ACKed
    independently of primary effects. Delivery failures remain pending. *)
val retry_pending_observations : base_path:string -> unit
(** Existing server maintenance calls this bounded wake-only edge. It wakes an
    existing owner only when its prior pass could not settle observations or
    complete its authoritative discovery. A failed subsequent pass preserves
    this demand; only a completed pass without observation errors clears it. The
    owner freshly reads original authority before retrying. The physical workspace
    path is resolved in the existing host-I/O executor. No timer, journal read,
    provider or domain work runs here, and shutdown owners stay stopped. *)
type refresh = Queued | No_owner | Unavailable of string
val request : base_path:string -> refresh
(** Signal the existing owner only; no storage or model work in the caller. *)
module For_testing : sig
  type idle_checkpoint
  type idle_result = Owner_idle of idle_checkpoint | Owner_stopped | Owner_missing
  type snapshot =
    { pending : bool
    ; in_flight : bool
    ; observation_retry : bool
    ; stopped : bool
    ; idle_waiters : int
    }
  val snapshot : base_path:string -> snapshot option
  (** None means there is no owner for this physical workspace. *)
  val await_idle : ?after:idle_checkpoint -> base_path:string -> unit -> idle_result
  (** Atomically check idle and subscribe under the original owner mutex.
      [after] waits for a later idle checkpoint, including one reached before
      subscription. Cancellation removes only this waiter. No deadline, wake,
      journal read, provider call or domain effect is introduced. A returned
      checkpoint observes idle at that instant; it does not freeze the owner. *)
  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end
