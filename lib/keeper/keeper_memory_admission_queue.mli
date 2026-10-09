(** Durable explicit-write candidates. Nothing in this store is current Memory.
    The queue is authoritative for pending input; Memory's range receipt is
    authoritative for consumption. A wake is only a notification. *)

type candidate =
  { sequence : int
  ; request_id : string
  ; fact : Keeper_memory_os_types.fact
  }

type batch

val candidates : batch -> candidate list
val range_id : batch -> Keeper_memory_os_current.explicit_write_range_id
(** Digest covers the exact ordered candidate payloads, including provenance. *)

val smaller_prefix : batch -> batch option
(** After a size refusal, select the first half of complete candidates. A
    singleton has no smaller nonempty prefix. Nothing is consumed or clipped. *)

val append :
  keepers_dir:string -> keeper_id:string -> request_id:string ->
  Keeper_memory_os_types.fact -> (candidate, string) result
(** Atomic pending append. Retrying an identity still pending returns the same
    candidate only if the entire fact matches. It never writes current Memory. *)

val read_pending :
  keepers_dir:string -> keeper_id:string -> (batch option, string) result
(** [None] means absent or empty. Malformed state is an error, never an empty queue. *)

val acknowledge_committed :
  keepers_dir:string -> keeper_id:string -> (unit, string) result
(** Recover Memory's committed explicit range, verify its generation and exact
    pending prefix, then atomically remove only that prefix. A newer appended
    tail survives. No caller-supplied success flag authorizes consumption.
    A positive acknowledged frontier without its committed receipt returns a
    recovery-required error before judging pending input. Restore the matching
    snapshot and receipt; this function never resets a generation or frontier
    to guess which inputs were consumed. *)

val path : keepers_dir:string -> keeper_id:string -> string
val list_keeper_ids : keepers_dir:string -> (string list, string) result
