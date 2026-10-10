(** Durable explicit-write candidates. Nothing in this store is current Memory.
    The queue is authoritative for pending input; Memory's candidate receipt is
    authoritative for consumption. A wake is only a notification. *)

type candidate =
  { sequence : int
  ; request_id : string
  ; fact : Keeper_memory_os_types.fact
  }

type batch

val candidates : batch -> candidate list
val candidate_ids : batch -> Keeper_memory_os_current.explicit_candidate_id list
(** One receipt identity per candidate in input order. Each digest covers the
    exact candidate JSON object (sequence, request ID, full fact/provenance),
    not an array. Original sparse sequence numbers are preserved. *)

val split : batch -> (batch * batch) option
(** After an actual size refusal, partition into two nonempty disjoint halves
    of complete candidates in original order. A singleton cannot split. This
    neither consumes input nor establishes semantic independence of the halves. *)

val append :
  keepers_dir:string -> keeper_id:string -> request_id:string ->
  Keeper_memory_os_types.fact -> (candidate, string) result
(** Atomic pending append. Retrying an identity still pending returns the same
    candidate only if the entire fact matches. It never writes current Memory.
    An append whose serialized queue would exceed the pending byte cap
    (MASC_KEEPER_MEMORY_OS_PENDING_MAX_BYTES, default 16 MiB) is refused
    before any write: the durable pending input is unchanged, and a drain
    that acknowledges committed candidates makes room for a later retry. *)

val read_pending :
  keepers_dir:string -> keeper_id:string -> (batch option, string) result
(** [None] means absent or empty. Malformed state is an error, never an empty queue. *)

val acknowledge_committed :
  keepers_dir:string -> keeper_id:string -> (unit, string) result
(** Read committed candidate receipts once, then under the queue lock verify
    generation and exact ID/sequence/payload matches before removing those rows.
    Deferred gaps and concurrently appended rows survive. Any receipt collision
    refuses the entire rewrite. No success flag authorizes consumption.
    Every sequence up to last_sequence that pending no longer holds must be
    named by a committed receipt of the generation; otherwise this returns a
    recovery-required error and leaves the queue unchanged, whether all or only
    some of those receipts are missing.
    The persisted last_sequence is never reduced, even when pending is empty. *)

val path : keepers_dir:string -> keeper_id:string -> string
val list_keeper_ids : keepers_dir:string -> (string list, string) result
