(** Concurrent preparation of directory chains for durable file publication.

    The module owns the process-local durability cache and coordinates only
    overlapping cold paths. Independent suffixes do not share a filesystem-I/O
    critical section. *)

type chain_error =
  | Non_directory_ancestor of { path : string }
  | Missing_root of { path : string }
  | Creation_not_observed of { path : string }

type failure =
  | Directory_chain_failed of chain_error
  | Operation_failed of exn * Printexc.raw_backtrace

val ensure
  :  before_prepare:(unit -> unit)
  -> before_directory_fsync:(string -> unit)
  -> string
  -> (unit, failure) result

val invalidate : string -> unit
val clear : unit -> unit

(** Blocking directory fsync primitive. Call only from a system-thread
    boundary. *)
val fsync_directory : string -> unit
