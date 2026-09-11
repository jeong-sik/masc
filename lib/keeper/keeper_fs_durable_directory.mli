(** Concurrent preparation of directory chains for durable file publication.

    The module owns the process-local durability cache and coordinates only
    overlapping cold paths. Independent suffixes do not share a filesystem-I/O
    critical section. Callers that enforce an ownership root validate that
    boundary before entering this durability cache.

    A caller parked on someone else's preparation receives that preparation's
    outcome: an ordinary failure is returned as its own error and the parked
    caller does not prepare the chain again, while a cancelled preparation
    releases its waiters to prepare it themselves. A caller that claims after
    the owner released the chain finds no preparation outstanding and becomes
    the next owner, so an ordinary failure is shared with the callers that
    were already waiting for it -- not with every later one. *)

type chain_error =
  | Non_directory_ancestor of { path : string }
  | Outside_ownership_root of
      { ownership_root : string
      ; path : string
      }
  | Missing_root of { path : string }
  | Creation_not_observed of { path : string }

type failure =
  | Directory_chain_failed of chain_error
  | Operation_failed of exn * Printexc.raw_backtrace

type lease

val ensure
  :  before_prepare:(unit -> unit)
  -> before_directory_fsync:(string -> unit)
  -> ?ownership_root:string
  -> string
  -> (lease, failure) result

val lease_is_current : lease -> bool
(** Lock-free validation that no invalidation at or above this directory has
    retired the durable chain observed by [ensure]. *)

val invalidate : string -> unit
val clear : unit -> unit

(** Blocking directory fsync primitive. Call only from a system-thread
    boundary. *)
val fsync_directory : string -> unit

module For_testing : sig
  (** Two synchronization boundaries. [after_validation] runs once the cache
      observation has found no usable lease. [before_claim] runs immediately
      before the claim itself, with nothing between it and either parking on
      another caller's preparation or becoming the owner.

      The gap between them is not empty: the root is anchored in a systhread
      there, which parks the fiber. So a test that has to arrange one caller
      as an already-parked waiter can only do it from [before_claim] --
      signalling from [after_validation] lets the scheduler run the other
      caller to completion first, which is what made the shared-failure case
      record a race instead of the contract (masc#35016). *)
  val ensure
    :  after_validation:(unit -> unit)
    -> before_claim:(unit -> unit)
    -> before_prepare:(unit -> unit)
    -> before_directory_fsync:(string -> unit)
    -> ?ownership_root:string
    -> string
    -> (lease, failure) result
end
