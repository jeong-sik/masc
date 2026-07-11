(** One structured-concurrency lane owned by one Keeper registry entry.

    The lane switch is created inside the forked fiber.  [exited] resolves
    only after [Eio.Switch.run] has joined every child fiber and released
    every resource attached to that switch. *)

type t

type outcome =
  | Completed
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

val start_error_to_string : start_error -> string

val create : unit -> t

val fork :
  sw:Eio.Switch.t ->
  t ->
  run:(Eio.Switch.t -> unit) ->
  cleanup:(outcome -> (unit, string) result) ->
  (unit, start_error) result

(** Resolve a lane for which the launch gate rejected the fiber before it
    started.  This keeps the join contract total for every registry entry. *)
val reject_before_start : t -> reason:exn -> (unit, start_error) result

val exited : t -> exit Eio.Promise.t
val peek_exit : t -> exit option
val await_exit : t -> exit
