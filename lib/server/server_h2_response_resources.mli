(** Application response payloads retained by an H2 listener. The capacity
    counts whole response copies and queued/in-flight streaming payloads;
    protocol frames, source/cache values and serialization temporaries are
    outside this ledger. It is not a process RSS limit. *)
type t
type request
type lease
type refusal = Capacity_exhausted | Request_closed

exception Unbound_request
exception Response_capacity_exhausted
exception Response_writer_closed

val create : max_pending_bytes:int -> t
val pending_bytes : t -> int
val with_request : t -> sw:Eio.Switch.t -> (unit -> 'a) -> 'a
(** Bind a request to its stream switch. Reset/connection cancellation releases
    its outstanding leases even if the H2 writer never invokes a flush callback. *)
val current_exn : unit -> request
val current : unit -> request option
(** [None] before an application request has been admitted, e.g. parser errors. *)
val with_current : request -> (unit -> 'a) -> 'a
val reserve : request -> bytes:int -> (lease, refusal) result
val release : lease -> unit
val write_reserved : lease -> H2.Body.Writer.t -> string -> unit
(** Copy the reserved payload, then release at flush. Switch cleanup is the
    alternate release path. A payload size mismatch is an invalid argument. *)
val write_and_flush : H2.Body.Writer.t -> string -> unit
(** One sequential producer. Wait for this frame outside shared publisher locks.
    Exhaustion and writer closure raise the corresponding exceptions. *)

type stream
val stream : H2.Body.Writer.t -> stream
val offer : stream -> string -> bool
(** Nonblocking producer: reserve bytes and enqueue an immutable frame. Capacity
    exhaustion closes this stream explicitly; it never silently drops a frame
    while reporting success. This callback does not mutate the H2 writer. *)
val is_closed : stream -> bool
val run : stream -> unit
(** Drain on the writer's domain, one flush at a time. Overflow wakes this fiber
    even while a prior frame is blocked by flow control. Cancellation releases
    queued and in-flight payloads. *)
