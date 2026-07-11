(** One structured-concurrency lane owned by one Keeper registry entry.

    The lane switch is created inside the forked fiber.  [exited] resolves
    only after [Eio.Switch.run] has joined every child fiber and released
    every resource attached to that switch. *)

type t

module Id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type outcome =
  | Completed
  | Shutdown_before_start
  | Shutdown_requested
  | Cancelled_by_parent of exn
  | Failed of exn

type exit =
  { outcome : outcome
  ; cleanup_error : string option
  }

type start_error =
  | Already_started
  | Already_exited
  | Fork_failed of exn

type cancel_result =
  | Cancel_requested
  | Cancel_already_requested
  | Cancel_already_exiting
  | Cancel_signal_failed of exn

val start_error_to_string : start_error -> string

val create : unit -> t
val id : t -> Id.t

val fork :
  sw:Eio.Switch.t ->
  t ->
  run:(Eio.Switch.t -> unit) ->
  cleanup:(outcome -> (unit, string) result) ->
  (unit, start_error) result
(** A fork rejected by an already-cancelling Eio switch returns
    [Error (Fork_failed _)] and resolves [exited]. Cleanup and exit resolution
    are exact-once even if switch cancellation races the child start. *)

(** Resolve a lane for which the launch gate rejected the fiber before it
    started.  This keeps the join contract total for every registry entry. *)
val reject_before_start : t -> reason:exn -> (unit, start_error) result

(** Request cancellation of this exact lane scope. The request is remembered
    even if the fiber has not attached its switch yet. This does not join; use
    [await_exit] for that boundary. *)
val request_cancel : t -> cancel_result

val shutdown_requested : t -> bool
(** [true] once [request_cancel] has been called on this lane. Lets a
    supervised body classify a resulting [Eio.Cancel.Cancelled] as an
    operator-sanctioned shutdown (graceful stop) rather than a parent/restart
    cancel, since both surface as the same exception. *)

val exited : t -> exit Eio.Promise.t
val peek_exit : t -> exit option
val await_exit : t -> exit
