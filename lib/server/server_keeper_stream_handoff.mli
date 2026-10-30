(** A subscription buffers live events until acceptance and replay finish.
    One sender drains its FIFO; concurrent or reentrant producers only enqueue
    while that sender is active. No send effect runs under the state mutex. *)
type 'a t

type delivery = Continue | Stop

val create : unit -> 'a t

val publish : 'a t -> send:('a -> delivery) -> 'a -> unit
(** Enqueue an event. After acceptance, the producer that acquires idle sender
    ownership drains the queue. Other producers do not wait for that sender. *)

val accept : 'a t -> send:('a -> delivery) -> unit
(** Finish buffering and drain held events before any later live event.
    Calling this again does not acquire a second sender. *)

val close : 'a t -> unit
(** Drop pending events and ignore future publication/acceptance. An already
    claimed send may finish. A [Stop] result or a send exception also closes the
    handoff; exceptions, including cancellation, propagate unchanged. *)
