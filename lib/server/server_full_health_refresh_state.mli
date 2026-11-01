(** Immutable full-health refresh bookkeeping. The shell owns locking,
    completion handles, clocks, fiber creation and publication effects. *)

type freshness =
  | Current_generation
  | Invalidated_during_refresh of float

type 'completion worker = private
  { id : int
  ; started_at : float
  ; completion : 'completion
  ; freshness : freshness
  ; failure_reported : bool
  ; was_requested : bool
  }

type flight =
  | Idle
  | In_flight of float option
(** Flight metadata is independent of shared worker ownership. A direct refresh
    can finish while a shared worker remains. A later waiter failure resumes
    in-flight metadata without inventing a start time. *)

type 'completion t = private
  { flight : flight
  ; direct_flight : float option
  ; requested : bool
  ; active_worker : 'completion worker option
  ; next_worker_id : int
  ; submissions : int
  ; joins : int
  ; invalidation_generation : int
  }

val empty : 'completion t
val request : 'completion t -> 'completion t
val begin_direct : now:float -> 'completion t -> 'completion t
val cancel_direct : was_requested:bool -> 'completion t -> 'completion t
(** Restore flight metadata when a direct refresh is cancelled before
    completing, preserving any active shared worker's original start timestamp
    and retaining whether a refresh was requested before or during the attempt. *)
val complete : refresh_requested:bool -> 'completion t -> 'completion t
(** Clear flight metadata and set the requested flag without removing a shared
    worker. The matching worker's ownership is settled by [take_worker]. *)

val note_failure : worker_active:bool -> 'completion t -> 'completion t
(** An active waiter failure preserves start/request metadata. Otherwise clear
    flight metadata and the request, without changing worker ownership. *)

type 'completion start_plan

type 'completion admission =
  | Join of 'completion t * 'completion worker
  | Start of 'completion start_plan

val admit : 'completion t -> 'completion admission
(** Joining increments the join count. [Start] holds a no-active-worker state;
    only this branch needs a new completion handle or observed start time.
    The shell keeps admission and start under the same lock. *)

val start :
  now:float -> completion:'completion -> 'completion start_plan ->
  'completion t * 'completion worker
(** Allocate the next worker identity in the admitted immutable state and
    increment submissions. No external work is performed here. *)

val take_worker :
  id:int -> 'completion t -> ('completion t * 'completion worker) option
(** [None] means no matching active worker; its completion must be ignored.
    A match removes only worker ownership and returns its freshness and
    once-only failure evidence unchanged. *)

val cancel_worker :
  id:int -> 'completion t -> ('completion t * bool) option
(** Settle a cancelled shared worker by removing its ownership, restoring any
    concurrent direct refresh's in-flight metadata (or [Idle] if none is in
    flight), and restoring any pre-existing or invalidation-triggered refresh
    request. The returned boolean is [true] when the worker was invalidated
    while active. *)

val note_wait_failure : 'completion t -> 'completion t option
(** Mark the active worker's first waiter failure. [None] means no active
    worker or that its failure was already reported; do not publish it again. *)

val invalidate : now:float -> 'completion t -> 'completion t
(** Request another refresh, advance the observation generation and retain
    the first invalidation time of an active worker. *)
