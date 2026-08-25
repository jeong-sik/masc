(** Process-local exclusion for concrete external resources.

    Keeper Owners remain independent. Only operations carrying the same
    resolved resource key wait for one another; unrelated paths and working
    directories continue concurrently. *)

type t =
  | File_path of string
  | Host_cwd of string

val with_lease : t -> (unit -> 'a) -> 'a
(** Run [f] while exclusively owning the exact resource. Waiting applies
    backpressure. Cancellation and exceptions always release the registry
    reference and the mutex. *)
