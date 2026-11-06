open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec

let pending_store_surface = "keeper_gate_pending"
let replay_results_store_surface = "keeper_gate_replay_results"
let pending_store_mutex = Cross_context_mutex.create ()
let deliveries : persisted_delivery SMap.t Atomic.t = Atomic.make SMap.empty
let unavailable_stores : storage_error SMap.t Atomic.t = Atomic.make SMap.empty
(* A partially readable snapshot remains unavailable for mutations, but its
   valid entries can still be shown to the operator. Keep the per-entry read
   errors separately so the projection distinguishes "no approvals" from
   "some approvals could not be read" without rewriting the source file. *)
let pending_read_errors : storage_error list SMap.t Atomic.t =
  Atomic.make SMap.empty
let replay_projection_errors : storage_error SMap.t Atomic.t =
  Atomic.make SMap.empty
;;

let store_revisions : int SMap.t Atomic.t = Atomic.make SMap.empty
(** Process projection of the next value persisted in each workspace snapshot. *)
let next_sequences : int SMap.t Atomic.t = Atomic.make SMap.empty
let first_sequence = 1

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

let durable_states : durable_state SMap.t Atomic.t = Atomic.make SMap.empty
let compaction_ratio = 2
let first_generation = 1

type write_mode =
  | Append_rows (* production: rows for what changed; the snapshot by ratio *)
  | Rewrite_snapshot
  (* test seams that inject the snapshot writer: exercise it on every write *)

let durable_state_for ~base_path = SMap.find_opt base_path (Atomic.get durable_states)

let set_durable_state ~base_path state =
  Atomic.set durable_states (SMap.add base_path state (Atomic.get durable_states))
;;

let drop_durable_state ~base_path =
  Atomic.set durable_states (SMap.remove base_path (Atomic.get durable_states))
;;

let next_generation ~base_path =
  match durable_state_for ~base_path with
  | Some state -> state.snapshot_generation + 1
  | None -> first_generation
;;

(** Serialize one durable pending/delivery snapshot transition across both Eio
    fibers and non-Eio callers.  A plain [Stdlib.Mutex.protect] is invalid here:
    snapshot publication uses [Eio.Path] and may suspend while the lock is held,
    letting another fiber on the same domain re-enter the OS mutex and raise
    [Sys_error "Mutex.lock: Resource deadlock avoided"].

    The shared cross-context authority keeps acquisition cancellable and defers
    cancellation only after both gates are held, so a published snapshot is not
    reported as an ambiguous cancelled operation. *)
let with_pending_store_lock f =
  Cross_context_mutex.with_durable_lock pending_store_mutex f
;;

let bump_store_revision_unlocked ~base_path =
  let revisions = Atomic.get store_revisions in
  let revision =
    match SMap.find_opt base_path revisions with
    | Some revision -> revision
    | None -> 0
  in
  Atomic.set store_revisions (SMap.add base_path (revision + 1) revisions)
;;

let mark_store_unavailable_unlocked ~base_path error =
  Atomic.set
    unavailable_stores
    (SMap.add base_path error (Atomic.get unavailable_stores));
  bump_store_revision_unlocked ~base_path
;;

let clear_store_unavailable_unlocked ~base_path =
  Atomic.set
    unavailable_stores
    (SMap.remove base_path (Atomic.get unavailable_stores));
  bump_store_revision_unlocked ~base_path
;;

let store_revision_unlocked ~base_path =
  Option.value
    (SMap.find_opt base_path (Atomic.get store_revisions))
    ~default:0
;;

let store_revision_for_workspace ~base_path =
  store_revision_unlocked ~base_path
;;

let pending_store_path ~base_path =
  Keeper_gate_path.pending ~base_path
;;

let pending_log_path ~base_path = Keeper_gate_path.pending_log ~base_path

let private_jsonl_error ~path error =
  { path; reason = Fs_compat.private_jsonl_transaction_error_to_string error }
;;

let observe_log_settlement ~path error =
  Log.Server.warn
    "gate_pending log descriptor settlement incomplete path=%s: %s"
    path
    (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let replay_results_store_path ~base_path =
  Keeper_gate_path.replay_results ~base_path
;;
