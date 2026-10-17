(** The in-memory pending queue of each Keeper, one cell per Keeper key,
    shared by every registry entry the Keeper gets. Both writes run under the
    Keeper's queue owner lock, so a commit is either in a registration's read
    or published to the cell the installed entry holds (#43494).

    Locks: a registration holds the queue owner lock only for its read and
    releases it before it takes the lifecycle key lock, so the two are never
    held together. A caller that holds the Keeper's intake mutex takes both
    inside it. The table's own mutex is taken inside the owner lock and takes
    nothing.

    A cell is never removed. A deleted Keeper's cell stays until the process
    ends; a later registration of that name refills it with its own read, so
    nothing of the deleted Keeper is handed out. *)

val set : base_path:string -> string -> Keeper_event_queue.t -> Keeper_event_queue.t Atomic.t
(** [set ~base_path name pending] puts [pending] in the Keeper's cell, making
    the cell if there is none, and returns it. A registration calls it with
    its read of the durable queue, under the queue owner lock. A registration
    refused after this call (a lifecycle reservation, an unreadable failure
    streak, an invalid entry) leaves that read in the cell: the durable
    queue's own value. *)

val publish : base_path:string -> string -> Keeper_event_queue.t -> unit
(** [publish ~base_path name pending] puts [pending] in the Keeper's cell when
    there is one. Each commit calls it from [after_commit], under the queue
    owner lock. A Keeper that has not registered in this process has no cell;
    its registration reads the durable queue. *)
