(** Ownership handoff for one client borrowed by a pool request. A request
    owns cleanup until the idle queue accepts the client or its daemon receives
    a close signal. Asking for release does not transfer ownership. *)

type t

val park : t -> publish:(unit -> unit) -> unit
(** Publish the client into the idle queue and transfer ownership together.
    [publish] is the pool's single, non-suspending queue mutation, called while
    holding its mutex. It must not perform further work after that mutation. *)

val close : t -> signal:(unit -> unit) -> unit
(** Send the client's non-suspending close signal and record the transfer.
    This does not wait for client teardown. *)

val with_client :
  release:(t -> close_only:bool -> unit) ->
  close:(unit -> unit) ->
  (release:(close_only:bool -> unit) -> 'a) -> 'a
(** Run a request with one release operation. On every exit, signal close if
    ownership has not transferred, without reacquiring the pool mutex or
    waiting for teardown. A release that raises before transfer remains the
    request's cleanup obligation; an exception after transfer cannot reclaim
    the idle queue's client. Repeated release after transfer does nothing. *)
