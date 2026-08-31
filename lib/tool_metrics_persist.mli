(** SQLite persistence for tool metrics.

    [.masc/tool-metrics.sqlite3] is the only durable copy. The in-memory
    {!Tool_metrics} value is a projection rebuilt from this database at
    startup. Writes are best-effort and never change a completed tool result.

    @since 2.108.0 — Issue #3280 *)

val enqueue : base_path:string -> Tool_result.result -> unit
(** Persist one completed tool invocation. This call writes directly to
    SQLite before returning; there is no process-local write queue. Storage
    failures are logged and counted, but do not raise into tool dispatch.
    WAL with [synchronous=NORMAL] preserves committed rows across process
    crashes; host power-loss durability is outside this contract. *)

type hydrate_report = {
  loaded_records : int;
  pruned_records : int;
}

val hydrate :
  base_path:string ->
  retention_days:int ->
  (hydrate_report, string) result
(** Delete rows older than [retention_days], then replace the in-memory
    aggregate with the retained rows. Call before installing live producers. *)

type store_summary = {
  path : string;
  exists : bool;
  entry_count : int;
  latest_ts : float option;
}

val store_summary : base_path:string -> (store_summary, string) result
(** Return the persisted row count and latest timestamp without changing the
    in-memory aggregate. A missing database is an empty, healthy store. *)

val read_recent :
  base_path:string ->
  ?since_ts:float ->
  ?until_ts:float ->
  n:int ->
  unit ->
  (Yojson.Safe.t list, string) result
(** Read at most [n] newest rows, newest first. [n <= 0] returns [[]]. *)

val database_path : base_path:string -> string
(** Canonical SQLite path under the cluster-aware MASC runtime root. *)

val reset_for_testing : unit -> unit
(** Close the cached database handle. Tests must call this only after all
    concurrent users have stopped. *)
