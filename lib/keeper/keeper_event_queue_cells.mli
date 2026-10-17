(** The in-memory pending queue of each Keeper, one cell per Keeper key,
    shared by every registry entry the Keeper gets. Both writes run under the
    Keeper's queue owner lock, so a commit is either in a registration's read
    or published to the cell the installed entry holds (#43494). *)

val set : base_path:string -> string -> Keeper_event_queue.t -> Keeper_event_queue.t Atomic.t
(** [set ~base_path name pending] puts [pending] in the Keeper's cell, making
    the cell if there is none, and returns it. A registration calls it with
    its read of the durable queue, under the queue owner lock. *)

val publish : base_path:string -> string -> Keeper_event_queue.t -> unit
(** [publish ~base_path name pending] puts [pending] in the Keeper's cell when
    there is one. Each commit calls it from [after_commit], under the queue
    owner lock. A Keeper that has not registered in this process has no cell;
    its registration reads the durable queue. *)
