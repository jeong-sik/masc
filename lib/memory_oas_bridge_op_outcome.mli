(** Memory_oas_bridge_op_outcome — closed sum naming each
    (operation, outcome) pair the JSONL-backed
    [Agent_sdk.Memory.long_term_backend] can produce.

    The sub-library [Memory_jsonl] is a dependency leaf (RFC-0056
    Phase 1F) and cannot increment Prometheus counters directly.
    {!Memory_oas_bridge.make_backend} wraps each of the 5 closures
    ([persist], [retrieve], [remove], [batch_persist], [query]) and
    increments [metric_keeper_memory_jsonl_ops] with the label
    derived from this type so operators can read success/failure
    rate per operation. *)

type t =
  | Persist_ok
      (** [persist] returned [Ok ()].  One key-value pair appended
          to the JSONL session file. *)
  | Persist_failed
      (** [persist] returned [Error _].  File system or encoding
          error; the warn line in [Memory_jsonl.persist] names the
          exception. *)
  | Retrieve_hit
      (** [retrieve] returned [Some _].  The key resolved to a
          non-tombstone value in the JSONL log. *)
  | Retrieve_miss
      (** [retrieve] returned [None].  Three causes collapse here:
          (a) key never written, (b) last write was a tombstone, (c)
          retrieve raised an exception that was caught and logged.
          Distinguishing (a)/(b)/(c) requires an OAS contract change
          and is out of scope for this PR. *)
  | Remove_ok
      (** [remove] returned [Ok ()]. *)
  | Remove_failed
      (** [remove] returned [Error _]. *)
  | Batch_persist_ok
      (** [batch_persist] returned [Ok ()].  Atomic multi-key
          append succeeded. *)
  | Batch_persist_failed
      (** [batch_persist] returned [Error _]. *)
  | Query_ok
      (** [query] returned (potentially empty) result list.  No
          [Error] path exists in the OAS contract for this op. *)

val to_label : t -> string
