(** Dedicated IO Eio domain hosting {!Masc_http_client.with_scoped_pool} for
    both request/response HTTP calls AND persistent SSE streams.

    Keeping persistent SSE readers on this dedicated domain ensures heavy UI
    frames never throttle SSE replay or stall socket reads. *)

exception Closed
(** Raised by {!run} when the IO domain is shutting down or has already closed
    before the submitted work could finish. *)

type t

val start : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t
(** Spawn the IO domain bound to [sw]. Finishing [sw] cancels all active HTTP
    requests and SSE streams on the IO domain, drains queued jobs so no waiter
    can hang, and closes the connection pool. *)

val run : t -> (unit -> 'a) -> 'a
(** Execute [work] on the IO domain and return its result to the calling fiber.
    Cancelling the calling fiber cancels [work]; a caller cancelled before
    entry leaves [work] unstarted. Raises {!Closed} if the IO domain shuts down
    before [work] completes. Re-raises work exceptions with their original
    backtrace. *)

type stream_handle
(** Cross-domain-safe handle to a long-lived SSE fiber running in its own child
    [Eio.Switch] on the IO domain. *)

val spawn_stream :
  ?on_error:(exn -> unit) -> t -> (sw:Eio.Switch.t -> unit) -> stream_handle
(** Enqueue a long-lived stream fiber on the IO domain inside a fresh child
    switch. Returns immediately without blocking the caller. Non-cancellation
    exceptions thrown by the stream are isolated to that stream (invoking
    [on_error] when provided) and never tear down sibling streams or requests. *)

val cancel_stream : stream_handle -> unit
(** Request cancellation of the stream fiber on the IO domain. Non-blocking and
    safe to call from any domain (including the UI domain). Idempotent. *)

val await_stream_stopped : stream_handle -> unit
(** Suspend until the stream fiber's child switch has exited (or the IO domain
    has drained the unstarted job on shutdown). *)

val is_stream_stopped : stream_handle -> bool
(** Non-blocking check whether the stream fiber has exited. *)
