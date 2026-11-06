(** The process-wide state of the durable approval queue in
    [Keeper_approval_queue].

    All of it is held in [Atomic.t] maps. [deliveries] holds the persisted
    deliveries by approval id. [unavailable_stores], [pending_read_errors],
    [replay_projection_errors], [store_revisions], [next_sequences] and
    [durable_states] are keyed by the base path of a workspace. A
    [durable_state] records what the last snapshot and the append log of one
    workspace hold, and [next_generation] gives the generation of the next
    snapshot. [write_mode] says whether a write appends rows or rewrites the
    snapshot.
    [with_pending_store_lock] serializes the transitions of the store across
    Eio fibers and non-Eio callers. The functions ending in [_unlocked] do not
    take it themselves. [mark_store_unavailable_unlocked] and
    [clear_store_unavailable_unlocked] change the unavailable mark of a
    workspace and raise its revision, and [store_revision_for_workspace] reads
    that revision without the lock.
    [pending_store_path], [pending_log_path] and [replay_results_store_path]
    name the files of a workspace; [private_jsonl_error] and
    [observe_log_settlement] report a failed append-log transaction.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_rules

val pending_store_surface : string

val replay_results_store_surface : string

val deliveries :
  persisted_delivery Set_util.StringMap.t
  Atomic.t

val unavailable_stores :
  storage_error Set_util.StringMap.t Atomic.t

val pending_read_errors :
  storage_error list Set_util.StringMap.t
  Atomic.t

val replay_projection_errors :
  storage_error Set_util.StringMap.t Atomic.t

val store_revisions : int Set_util.StringMap.t Atomic.t

val next_sequences : int Set_util.StringMap.t Atomic.t

val first_sequence : int

(* ── Append log beside the snapshot (RFC main-domain-scheduler-latency §8.5, P4e)

   The in-memory maps are the authority; the snapshot file plus the rows of
   [pending.log.jsonl] appended after it are the durable record of that
   state. A mutation appends only the entries that differ from the last
   durable state, compared by physical equality: entries are immutable
   records, so a changed entry is a new record and an unchanged one is the
   same pointer. The snapshot is rewritten, and the log emptied, only when
   the rows outnumber [compaction_ratio] times the entries they describe, or
   when the log is not what memory believes it is. Measured 2026-09-05: every
   mutation rewrote the 23 MB pretty-printed snapshot, 12 to 14 GB allocated
   per four minutes across the fleet. *)
type durable_state =
  { durable_pending : pending_approval SMap.t (* this workspace's entries *)
  ; durable_deliveries : persisted_delivery SMap.t
  ; snapshot_generation : int (* of the snapshot the log rows extend *)
  ; log_cursor : Fs_compat.Private_jsonl_cursor.t
  ; log_rows : int (* rows appended since the snapshot was written *)
  }

val durable_states : durable_state Set_util.StringMap.t Atomic.t

val compaction_ratio : int

val first_generation : int

type write_mode =
  | Append_rows (* production: rows for what changed; the snapshot by ratio *)
  | Rewrite_snapshot
  (* test seams that inject the snapshot writer: exercise it on every write *)

val durable_state_for : base_path:string -> durable_state option

val set_durable_state : base_path:string -> durable_state -> unit

val drop_durable_state : base_path:string -> unit

val next_generation : base_path:string -> int

val with_pending_store_lock : (unit -> 'a) -> 'a

val bump_store_revision_unlocked : base_path:string -> unit

val mark_store_unavailable_unlocked :
  base_path:string -> storage_error -> unit

val clear_store_unavailable_unlocked : base_path:string -> unit

val store_revision_unlocked : base_path:string -> int

val store_revision_for_workspace : base_path:string -> int

val pending_store_path : base_path:string -> string

val pending_log_path : base_path:string -> string

val private_jsonl_error :
  path:string ->
  Fs_compat.private_jsonl_transaction_error ->
  storage_error

val observe_log_settlement :
  path:string -> Fs_compat.private_jsonl_transaction_error -> unit

val replay_results_store_path : base_path:string -> string
