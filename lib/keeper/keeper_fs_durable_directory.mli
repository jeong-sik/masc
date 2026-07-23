(** Concurrent preparation of directory chains for durable file publication.

    The module owns the process-local durability cache and coordinates only
    overlapping cold paths. Independent suffixes do not share a filesystem-I/O
    critical section. Callers that enforce an ownership root validate that
    boundary before entering this durability cache. *)

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
  (** [after_validation] is an immutable synchronization boundary between the
      cache observation and preparation claim. *)
  val ensure
    :  after_validation:(unit -> unit)
    -> before_prepare:(unit -> unit)
    -> before_directory_fsync:(string -> unit)
    -> ?ownership_root:string
    -> string
    -> (lease, failure) result
end
