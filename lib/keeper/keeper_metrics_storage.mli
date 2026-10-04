(** Date-sharded turn/heartbeat metric storage. The configured byte target is
    captured once for both rotation and pruning; readers share the same store. *)
type t

val create : base_dir:string -> max_bytes:int -> t
(** Nonpositive [max_bytes] keeps all records. A positive target rotates the
    current file and prunes oldest completed files after an append. The newest
    row is preserved even when that one row exceeds the target. Cleanup is
    best effort under the underlying Dated_jsonl I/O contract. *)

val read_store : t -> Dated_jsonl.t

val append : t -> Yojson.Safe.t -> unit
(** Append a metric, rotating and pruning under the shared store mutex.
    A refused append raises [Sys_error] instead of reporting a successful write. *)
