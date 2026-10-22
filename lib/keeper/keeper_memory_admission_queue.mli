(** Durable explicit-write candidates. Nothing in this store is current Memory.
    The queue is authoritative for pending input; Memory's candidate receipt is
    authoritative for consumption. A wake is only a notification. *)

type candidate =
  { sequence : int
  ; request_id : string
  ; fact : Keeper_memory_os_types.fact
  }

type batch

type append_error =
  | Capacity_exceeded of { required_bytes : int; limit_bytes : int }
  | Append_failed of string

val append_error_to_string : append_error -> string
(** Presentation only. Callers decide effect certainty from the variant. *)

val candidates : batch -> candidate list
val candidate_ids : batch -> Keeper_memory_os_current.explicit_candidate_id list
(** One receipt identity per candidate in input order. Each digest covers the
    exact candidate JSON object (sequence, request ID, full fact/provenance),
    not an array. Original sparse sequence numbers are preserved. *)

val batch_to_json : batch -> Yojson.Safe.t
val batch_of_json :
  expected_candidate_ids:Keeper_memory_os_current.explicit_candidate_id list ->
  Yojson.Safe.t -> (batch, string) result
(** Preserve and restore a nonempty original batch without reading today's
    queue. The closed envelope carries its generation and complete ordered
    candidates, including fact provenance and sparse sequence numbers.
    Restoration requires exact equality with the independently retained original
    candidate identities, in order: generation, request ID, sequence and full
    candidate payload digest. Unknown/duplicate fields, nonascending rows,
    duplicate request IDs and missing/extra/changed candidates are refused.

    The expected identities must come from the trusted original host capture,
    never the worker or this JSON itself. This only restores input data; the
    original consumer must separately restore workspace/Keeper/installation
    ownership, Memory inputs and request ancestry. It neither authorizes a model
    call nor consumes a candidate. Commit and ACK still use the existing locked
    Memory disposition and verified committed candidate receipts. *)

val split : batch -> (batch * batch) option
(** After an actual size refusal, partition into two nonempty disjoint halves
    of complete candidates in original order. A singleton cannot split. This
    neither consumes input nor establishes semantic independence of the halves. *)

val append :
  keepers_dir:string -> keeper_id:string -> request_id:string ->
  Keeper_memory_os_types.fact -> (candidate, append_error) result
(** Atomic pending append. Retrying an identity still pending returns the same
    candidate only if the entire fact matches. It never writes current Memory.
    An append whose serialized queue would exceed the pending byte cap
    (MASC_KEEPER_MEMORY_OS_PENDING_MAX_BYTES, default 16 MiB) is refused
    as [Capacity_exceeded] before any write: the durable pending input is unchanged, and a drain
    that acknowledges committed candidates makes room for a later retry.
    [Append_failed] does not establish whether a write committed. *)

val read_pending :
  keepers_dir:string -> keeper_id:string -> (batch option, string) result
(** [None] means absent or empty. Malformed state is an error, never an empty queue. *)

val acknowledge_committed :
  keepers_dir:string -> keeper_id:string -> (unit, string) result
(** Read committed candidate receipts once, then under the queue lock verify
    generation and exact ID/sequence/payload matches before removing those rows.
    Deferred gaps and concurrently appended rows survive. Any receipt collision
    refuses the entire rewrite. No success flag authorizes consumption.
    A consumed sequence whose receipt is gone holds back nothing: it is no
    longer input. A pending row whose receipt is missing cannot be told apart
    from input never committed, so it stays pending and is judged again against
    current Memory. Memory the receipts cannot be verified against refuses
    before any rewrite. The persisted last_sequence is never reduced, even when
    pending is empty. *)

val path : keepers_dir:string -> keeper_id:string -> string
val list_keeper_ids : keepers_dir:string -> (string list, string) result

module For_testing : sig
  val acknowledge_with :
    read_receipts:(queue_generation:string ->
      (Keeper_memory_os_current.explicit_candidate_id list, string) result) ->
    keepers_dir:string -> keeper_id:string -> (unit, string) result
end
