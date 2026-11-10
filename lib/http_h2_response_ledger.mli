(** Application response payloads retained by an H2 listener. The capacity
    counts whole response copies and queued/in-flight streaming payloads;
    protocol frames, source/cache values and serialization temporaries are
    outside this ledger. It is not a process RSS limit. *)
type t
type request
type lease
type refusal = Capacity_exhausted | Request_closed

exception Unbound_request

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
val write_reserved
  :  lease
  -> write:(H2.Body.Writer.t -> string -> unit)
  -> H2.Body.Writer.t
  -> string
  -> unit
(** [write_reserved lease ~write writer payload] copies the reserved payload
    into [writer] with [write], then releases at flush. Switch cleanup is the
    alternate release path. A payload size mismatch is an invalid argument.

    The flush that releases is h2's own and has no stall bound. A stream's
    bound counts the flushes [write] and the caller make through
    [Http_h2_stream.Stream_end]: the slice boundaries, and the caller's
    flush or close after the payload. *)
