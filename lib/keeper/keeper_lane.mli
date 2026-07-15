(** One structured-concurrency lane owned by one Keeper registry entry.

    A cancellation context is attached as soon as the forked fiber starts,
    before the run-scope admission boundary can wait. The child-owning lane
    switch is nested inside that run scope. [exited] therefore resolves only
    after every child has joined and every full-lane resource has been
    released, while an individual cancellation can also interrupt a blocked
    admission. *)

type t

module Id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type shutdown_cancel_failure =
  { cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

type outcome =
  | Completed
  | Shutdown_before_start
  | Shutdown_requested
  | Shutdown_cancel_failed of shutdown_cancel_failure
  | Cancelled_by_parent of exn
  | Failed of exn

type exit =
  { outcome : outcome
  ; cleanup_error : string option
  }

type cancellation_origin =
  | Shutdown_request
  | External_cancel of exn

type start_error =
  | Already_started
  | Already_exited
  | Fork_failed of exn

type cancel_result =
  | Cancel_requested
  | Cancel_already_requested
  | Cancel_already_exiting
  | Cancel_wrong_domain
  | Cancel_not_committed of exn
  | Cancel_committed_with_failure of exn

val start_error_to_string : start_error -> string

val create : unit -> t
val id : t -> Id.t

val fork :
  sw:Eio.Switch.t ->
  t ->
  with_run_scope:((unit -> unit) -> unit) ->
  run:(Eio.Switch.t -> unit) ->
  cleanup:(outcome -> (unit, string) result) ->
  (unit, start_error) result
(** A fork rejected by an already-cancelling Eio switch returns
    [Error (Fork_failed _)] and resolves [exited]. Cleanup and exit resolution
    are exact-once even if switch cancellation races the child start.
    [with_run_scope] must own every resource whose lifetime is the full Keeper
    lane; it wraps the child-owning lane switch itself, so it returns only
    after all lane children have joined. The separately attached cancellation
    context makes cancellation total before admission completes without
    recording a competing switch failure that could erase release evidence. *)

(** Resolve a lane for which the launch gate rejected the fiber before it
    started.  This keeps the join contract total for every registry entry. *)
val reject_before_start : t -> reason:exn -> (unit, start_error) result

(** Request cancellation of this exact lane scope. The request is remembered
    even if the fiber has not attached its cancellation context yet. This does
    not join; use [await_exit] for that boundary. A cancellation callback can
    fail after Eio has committed the context to cancellation; that distinct
    result must not be retried as if no signal had been delivered. Eio owns
    attached cancellation contexts per domain, so a request from another
    domain is rejected without changing a running lane. *)
val request_cancel : t -> cancel_result

val classify_cancellation_cause : exn -> cancellation_origin
(** Classify the payload of [Eio.Cancel.Cancelled] by exact exception identity.
    Supervised lane bodies use this instead of inferring cancellation origin
    from lifecycle timing or exception text. *)

val exited : t -> exit Eio.Promise.t
val peek_exit : t -> exit option
val await_exit : t -> exit
