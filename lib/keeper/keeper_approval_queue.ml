(** Durable, nonblocking HITL requests for Keeper external effects. *)

open Keeper_approval_queue_rules_types
open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_state

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

let report_pending_read_drop ~reason ~path ~detail =

  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", pending_store_surface; "reason", reason_wire ]
        ())
    ~surface:pending_store_surface
    ~reason
    ~path
    ~detail
;;

let report_replay_results_read_drop ~reason ~path ~detail =

  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:
          [ "surface", replay_results_store_surface
          ; "reason", reason_wire
          ]
        ())
    ~surface:replay_results_store_surface
    ~reason
    ~path
    ~detail
;;

let save_snapshot_file_unlocked
      ~base_path
      ~next_sequence
      ~generation
      ~pending_map
      ~delivery_map
    =
    let path = pending_store_path ~base_path in
    try
      Fs_compat.mkdir_p (Filename.dirname path);
      let body =
        snapshot_to_yojson ~base_path ~next_sequence ~generation ~pending_map ~delivery_map
        |> Yojson.Safe.to_string
      in
      (match Fs_compat.save_file_atomic path body with
       | Ok () -> Ok ()
       | Error reason -> Error { path; reason })
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

let save_snapshot_file_strict_staged_unlocked
      ~save_file_atomic_strict_staged
      ~base_path
      ~next_sequence
      ~generation
      ~pending_map
      ~delivery_map
  =
  let path = pending_store_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let body =
      snapshot_to_yojson ~base_path ~next_sequence ~generation ~pending_map ~delivery_map
      |> Yojson.Safe.to_string
    in
    match save_file_atomic_strict_staged path body with
    | Ok () -> Ok Fsync_completed
    | Error (failure : Fs_compat.atomic_replace_failure) ->
      let reason = Fs_compat.atomic_replace_failure_to_string failure in
      (match failure.stage with
       | Fs_compat.Before_rename ->
         (match failure.exception_ with
          | Eio.Cancel.Cancelled _ ->
            Printexc.raise_with_backtrace failure.exception_ failure.backtrace
          | _ -> Error { path; reason })
       | Fs_compat.After_rename -> Ok (Visible_sync_unconfirmed reason))
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn backtrace
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

let save_replay_results_file_unlocked ~base_path ~delivery_map =
  let path = replay_results_store_path ~base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let body =
      replay_results_to_yojson ~base_path ~delivery_map
      |> Yojson.Safe.pretty_to_string
    in
    match Fs_compat.save_file_atomic_strict_staged path body with
    | Ok () -> Ok Fsync_completed
    | Error (failure : Fs_compat.atomic_replace_failure) ->
      let reason = Fs_compat.atomic_replace_failure_to_string failure in
      (match failure.stage with
       | Fs_compat.Before_rename ->
         (match failure.exception_ with
          | Eio.Cancel.Cancelled _ ->
            Printexc.raise_with_backtrace failure.exception_ failure.backtrace
          | _ -> Error { path; reason })
       | Fs_compat.After_rename -> Ok (Visible_sync_unconfirmed reason))
  with
  | Eio.Cancel.Cancelled _ as exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn backtrace
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

(* Both publish paths below end the same way: a write that landed changed what
   this queue publishes, and a write that failed took the store out of service.
   The revision they move is what {!store_revision_for_workspace} answers, and
   the dashboard's Gate projection is cached under a key built from it.

   Until 2026-08-31 only the two availability transitions moved it, so a
   landed write -- an enqueue, a resolution, a completed delivery -- left the
   key unchanged and every reader kept the pre-write snapshot for the cache's
   whole life. A resolved approval was therefore republished as still pending,
   and an operator answering it from the TUI saw the row come back on the next
   poll and answered it again: one approval in the live workspace carries three
   [resolved] audit rows from a single actor minutes apart. *)
let publish_snapshot_outcome ~base_path result =
  (match result with
   | Ok _ -> bump_store_revision_unlocked ~base_path
   | Error error -> mark_store_unavailable_unlocked ~base_path error);
  result
;;

(* Writes the snapshot at the next generation, then empties the log at its
   current end. The snapshot holds every row, so a crash between the two
   leaves rows of an older generation behind, and the load ignores those.
   If emptying the log fails after the snapshot was written, the durable
   state is still complete on disk; the state is dropped here so the next
   write rewrites again instead of appending after an unknown cursor. *)
let compact_unlocked ~write_snapshot ~base_path ~pending_map ~delivery_map =
  let generation = next_generation ~base_path in
  match write_snapshot ~generation with
  | Error _ as error -> error
  | Ok outcome ->
    let path = pending_log_path ~base_path in
    let emptied =
      Eio_guard.run_in_systhread ~label:"approval-queue-read" (fun () ->
        match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
        | Error error -> Error error
        | Ok snapshot ->
          Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
            path
            ~expected:snapshot.Fs_compat.cursor
            "")
    in
    (match Fs_compat.private_jsonl_cursor_success_receipt emptied with
     | Error error ->
       Log.Server.warn
         "gate_pending log could not be emptied after snapshot generation %d path=%s: %s"
         generation
         path
         (Fs_compat.private_jsonl_transaction_error_to_string error);
       drop_durable_state ~base_path
     | Ok { Fs_compat.value = cursor; settlement_error } ->
       Option.iter (observe_log_settlement ~path) settlement_error;
       set_durable_state
         ~base_path
         { durable_pending = entries_for_base ~base_path pending_map Fun.id
         ; durable_deliveries =
             entries_for_base ~base_path delivery_map (fun delivery -> delivery.entry)
         ; snapshot_generation = generation
         ; log_cursor = cursor
         ; log_rows = 0
         });
    Ok outcome
;;

let persist_delta_unlocked
      ~write_mode
      ~write_snapshot
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  =
  let compact () = compact_unlocked ~write_snapshot ~base_path ~pending_map ~delivery_map in
  match write_mode, durable_state_for ~base_path with
  | Rewrite_snapshot, _ | Append_rows, None -> compact ()
  | Append_rows, Some durable ->
    let after_pending = entries_for_base ~base_path pending_map Fun.id in
    let after_deliveries =
      entries_for_base ~base_path delivery_map (fun delivery -> delivery.entry)
    in
    (match
       delta_rows
         ~before_pending:durable.durable_pending
         ~before_deliveries:durable.durable_deliveries
         ~after_pending
         ~after_deliveries
     with
     | [] -> Ok Fsync_completed
     | rows ->
       let entries = SMap.cardinal after_pending + SMap.cardinal after_deliveries in
       let rows_after = durable.log_rows + List.length rows in
       if rows_after > compaction_ratio * entries
       then compact ()
       else (
         let path = pending_log_path ~base_path in
         let suffix =
           String.concat
             ""
             (List.map
                (fun row ->
                   Yojson.Safe.to_string
                     (log_row_to_yojson
                        ~generation:durable.snapshot_generation
                        ~next_sequence
                        row)
                   ^ "\n")
                rows)
         in
         match
           Eio_guard.run_in_systhread ~label:"approval-queue-append" (fun () ->
             Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
               path
               ~expected:durable.log_cursor
               suffix)
         with
         | Error (Fs_compat.Cursor_mismatch _) ->
           (* The log is not what memory believes; memory is the authority,
              so rewrite both. *)
           compact ()
         | appended ->
           (match Fs_compat.private_jsonl_cursor_success_receipt appended with
            | Error error -> Error (private_jsonl_error ~path error)
            | Ok { Fs_compat.value = cursor; settlement_error } ->
              set_durable_state
                ~base_path
                { durable with
                  durable_pending = after_pending
                ; durable_deliveries = after_deliveries
                ; log_cursor = cursor
                ; log_rows = rows_after
                };
              Ok
                (match settlement_error with
                 | None -> Fsync_completed
                 | Some error ->
                   Visible_sync_unconfirmed
                     (Fs_compat.private_jsonl_transaction_error_to_string error)))))
;;

let persist_snapshot_with_sequence_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error error
  | None ->
    let write_snapshot ~generation =
      Result.map
        (fun () -> Fsync_completed)
        (save_snapshot_file_unlocked
           ~base_path
           ~next_sequence
           ~generation
           ~pending_map
           ~delivery_map)
    in
    publish_snapshot_outcome
      ~base_path
      (match
         persist_delta_unlocked
           ~write_mode:Append_rows
           ~write_snapshot
           ~base_path
           ~next_sequence
           ~pending_map
           ~delivery_map
       with
       | Error _ as error -> error
       | Ok Fsync_completed -> Ok ()
       | Ok (Visible_sync_unconfirmed reason) ->
         Log.Server.warn
           "gate_pending log append visible but durability unconfirmed workspace=%s: %s"
           base_path
           reason;
         Ok ())
;;

type store_lifecycle =
  | Uninstalled
  | Ready of int
  | Unavailable of storage_error

let next_sequence_lifecycle ~base_path =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Unavailable error
  | None ->
    (match SMap.find_opt base_path (Atomic.get next_sequences) with
     | Some sequence -> Ready sequence
     | None -> Uninstalled)
;;

let persist_snapshot_unlocked ~base_path ~pending_map ~delivery_map =
  match next_sequence_lifecycle ~base_path with
  | Ready next_sequence ->
    persist_snapshot_with_sequence_unlocked
      ~base_path
      ~next_sequence
      ~pending_map
      ~delivery_map
  | Uninstalled ->
    Error
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; install_persistence must \
           complete before publishing"
      }
  | Unavailable error -> Error error
;;

let persist_snapshot_exact_unlocked
      ~save_file_atomic_strict_staged
      ~write_mode
      ~base_path
      ~pending_map
      ~delivery_map
  =
  match next_sequence_lifecycle ~base_path with
  | Ready next_sequence ->
    let write_snapshot ~generation =
      save_snapshot_file_strict_staged_unlocked
        ~save_file_atomic_strict_staged
        ~base_path
        ~next_sequence
        ~generation
        ~pending_map
        ~delivery_map
    in
    publish_snapshot_outcome
      ~base_path
      (persist_delta_unlocked
         ~write_mode
         ~write_snapshot
         ~base_path
         ~next_sequence
         ~pending_map
         ~delivery_map)
  | Uninstalled ->
    Error
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; install_persistence must \
           complete before publishing"
      }
  | Unavailable error -> Error error
;;

type log_read =
  { log_pending : pending_approval SMap.t
  ; log_deliveries : persisted_delivery SMap.t
  ; log_next_sequence : int
  ; log_end : Fs_compat.Private_jsonl_cursor.t
  ; rows_applied : int
  ; partial_tail : bool
  }

(* Rows of a generation older than the snapshot's were written before its
   last rewrite and are already inside it. A newer generation cannot exist.
   A final line without its newline is a row whose durable append did not
   finish; it is dropped here and the install rewrites the snapshot. Any
   other unreadable row fails closed, as an unreadable snapshot does. *)
let read_pending_log_unlocked
      ~base_path
      ~snapshot_generation
      ~pending_map
      ~delivery_map
      ~next_sequence
  =
  let path = pending_log_path ~base_path in
  let log_result =
    match
      Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
      |> Fs_compat.private_jsonl_snapshot_success_receipt
    with
    | Ok receipt -> Ok (receipt, false)
    | Error (Fs_compat.Incomplete_transaction_tail _)
    | Error
        (Fs_compat.Transaction_settlement_failed
          { primary = Fs_compat.Transaction_failed (Fs_compat.Incomplete_transaction_tail _); _ }) ->
      (match
         Fs_compat.recover_private_jsonl_durable_locked_result path
         |> Fs_compat.private_jsonl_snapshot_success_receipt
       with
       | Ok receipt -> Ok (receipt, true)
       | Error error -> Error error)
    | Error error -> Error error
  in
  match log_result with
  | Error error -> Error (private_jsonl_error ~path error)
  | Ok ({ Fs_compat.value = snapshot; settlement_error }, recovered_tail) ->
    Option.iter (observe_log_settlement ~path) settlement_error;
    let bytes = snapshot.Fs_compat.bytes in
    let partial_tail =
      recovered_tail
      || (String.length bytes > 0
          && not (Char.equal bytes.[String.length bytes - 1] '\n'))
    in
    let lines = String.split_on_char '\n' bytes in
    let lines =
      if partial_tail && not recovered_tail
      then (
        match List.rev lines with
        | _partial :: complete -> List.rev complete
        | [] -> [])
      else lines
    in
    let applied =
      List.fold_left
        (fun accumulator line ->
           match accumulator with
           | Error _ as error -> error
           | Ok (pending_map, delivery_map, next_sequence, rows) ->
             if String.equal (String.trim line) ""
             then Ok (pending_map, delivery_map, next_sequence, rows)
             else (
               match Yojson.Safe.from_string line with
               | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
               | json ->
                 (match log_row_of_yojson ~base_path json with
                  | Error _ as error -> error
                  | Ok decoded ->
                    if decoded.row_generation < snapshot_generation
                    then Ok (pending_map, delivery_map, next_sequence, rows)
                    else if decoded.row_generation > snapshot_generation
                    then
                      Error
                        (Printf.sprintf
                           "row generation %d is ahead of snapshot generation %d"
                           decoded.row_generation
                           snapshot_generation)
                    else (
                      let pending_map, delivery_map =
                        apply_log_row (pending_map, delivery_map) decoded.row
                      in
                      Ok
                        ( pending_map
                        , delivery_map
                        , max next_sequence decoded.row_next_sequence
                        , rows + 1 )))))
        (Ok (pending_map, delivery_map, next_sequence, 0))
        lines
    in
    (match applied with
     | Error reason -> Error { path; reason }
     | Ok (log_pending, log_deliveries, log_next_sequence, rows_applied) ->
       Ok
         { log_pending
         ; log_deliveries
         ; log_next_sequence
         ; log_end = snapshot.Fs_compat.cursor
         ; rows_applied
         ; partial_tail
         })
;;

(* What a restart would see: the snapshot plus the log rows after it. No
   classification, no write. *)
let read_durable_unlocked ~base_path =
  let path = pending_store_path ~base_path in
  if not (Sys.file_exists path)
  then Ok (SMap.empty, SMap.empty, first_sequence, first_generation, [], None)
  else (
    match Safe_ops.read_json_file_safe path with
    | Error reason -> Error { path; reason }
    | Ok json ->
      (match snapshot_of_yojson ~base_path json with
       | Error reason -> Error { path; reason }
       | Ok (pending_map, delivery_map, next_sequence, generation, entry_errors) ->
         (match
            read_pending_log_unlocked
              ~base_path
              ~snapshot_generation:generation
              ~pending_map
              ~delivery_map
              ~next_sequence
          with
          | Error _ as error -> error
          | Ok log ->
            Ok
              ( log.log_pending
              , log.log_deliveries
              , log.log_next_sequence
              , generation
              , entry_errors
              , Some log ))))
;;

let load_snapshot_unlocked ~base_path :
    ( pending_approval SMap.t
      * persisted_delivery SMap.t
      * int
      * storage_error list
      * durable_state option
    , storage_error )
    result =
  let path = pending_store_path ~base_path in
  try
    if not (Sys.file_exists path)
    then
      (* A missing snapshot is a reset store. Rows left in the log describe
         nothing; they are dropped when the first write rewrites both. *)
      Ok (SMap.empty, SMap.empty, first_sequence, [], None)
    else (
      match Safe_ops.read_json_file_safe path with
      | Error reason ->
        report_pending_read_drop
          ~reason:Read_drop_reason.Entry_load_error
          ~path
          ~detail:reason;
        Error { path; reason }
      | Ok json ->
        (match
           Result.bind (snapshot_of_yojson ~base_path json) (fun decoded ->
             let ( pending_map
                 , delivery_map
                 , next_sequence
                 , generation
                 , pending_entry_errors )
               =
               decoded
             in
             match
               read_pending_log_unlocked
                 ~base_path
                 ~snapshot_generation:generation
                 ~pending_map
                 ~delivery_map
                 ~next_sequence
             with
             | Error error -> Error (storage_error_to_string error)
             | Ok log -> Ok (log, generation, pending_entry_errors))
         with
         | Ok (log, loaded_generation, pending_entry_errors) ->
           let loaded_pending = log.log_pending in
           let loaded_deliveries = log.log_deliveries in
           let loaded_next_sequence = log.log_next_sequence in
           let pending_read_errors =
             List.map (fun reason -> { path; reason }) pending_entry_errors
           in
           List.iter
             (fun (error : storage_error) ->
                report_pending_read_drop
                  ~reason:Read_drop_reason.Invalid_payload
                  ~path
                  ~detail:error.reason)
             pending_read_errors;
           let pending_changed, loaded_pending =
             classify_restarted_pending loaded_pending
           in
           let deliveries_changed, loaded_deliveries =
             classify_restarted_deliveries loaded_deliveries
           in
           let durable =
             { durable_pending = loaded_pending
             ; durable_deliveries = loaded_deliveries
             ; snapshot_generation = loaded_generation
             ; log_cursor = log.log_end
             ; log_rows = log.rows_applied
             }
           in
           if
             pending_read_errors = []
             && (pending_changed || deliveries_changed || log.partial_tail)
           then (
             set_durable_state ~base_path durable;
             let write_snapshot ~generation =
               Result.map
                 (fun () -> Fsync_completed)
                 (save_snapshot_file_unlocked
                    ~base_path
                    ~next_sequence:loaded_next_sequence
                    ~generation
                    ~pending_map:loaded_pending
                    ~delivery_map:loaded_deliveries)
             in
             match
               compact_unlocked
                 ~write_snapshot
                 ~base_path
                 ~pending_map:loaded_pending
                 ~delivery_map:loaded_deliveries
             with
             | Error _ as error -> error
             | Ok (Fsync_completed | Visible_sync_unconfirmed _) ->
               Log.Server.warn
                 "gate_pending restart rewrite workspace=%s classification=%b partial_log_tail=%b"
                 base_path
                 (pending_changed || deliveries_changed)
                 log.partial_tail;
               Ok
                 ( loaded_pending
                 , loaded_deliveries
                 , loaded_next_sequence
                 , pending_read_errors
                 , durable_state_for ~base_path ))
           else
             Ok
               ( loaded_pending
               , loaded_deliveries
               , loaded_next_sequence
               , pending_read_errors
               , Some durable )
         | Error reason ->
           report_pending_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path
             ~detail:reason;
           Error { path; reason }))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_pending_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:reason;
    Error { path; reason }
;;

let attach_replay_results ~delivery_map replay_results =
  SMap.fold
    (fun approval_id outcome result ->
       match result with
       | Error _ as error -> error
       | Ok deliveries ->
         (match SMap.find_opt approval_id deliveries with
          | None ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s has no matching delivery"
                 approval_id)
          | Some
              ( { decision = Decision.Approve
                ; grant_consumed = true
                ; replay_outcome = None
                ; _
                } as delivery ) ->
            Ok
              (SMap.add
                 approval_id
                 { delivery with replay_outcome = Some outcome }
                 deliveries)
          | Some { decision = Decision.Approve; grant_consumed = false; _ } ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s requires a consumed approve grant"
                 approval_id)
          | Some
              { decision = Decision.Reject _; _ } ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s belongs to a non-approved delivery"
                 approval_id)
          | Some { replay_outcome = Some _; _ } ->
            Error
              (Printf.sprintf
                 "gate_replay_results outcome %s is duplicated in memory"
                 approval_id)))
    replay_results
    (Ok delivery_map)
;;

let load_replay_results_unlocked ~base_path ~delivery_map =
  let path = replay_results_store_path ~base_path in
  try
    if not (Sys.file_exists path)
    then delivery_map, None
    else (
      match Safe_ops.read_json_file_safe path with
      | Error reason ->
        report_replay_results_read_drop
          ~reason:Read_drop_reason.Entry_load_error
          ~path
          ~detail:reason;
        delivery_map, Some { path; reason }
      | Ok json ->
        (match replay_results_of_yojson json with
         | Error reason ->
           report_replay_results_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path
             ~detail:reason;
           delivery_map, Some { path; reason }
         | Ok replay_results ->
           (match attach_replay_results ~delivery_map replay_results with
            | Ok delivery_map -> delivery_map, None
            | Error reason ->
              report_replay_results_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path
                ~detail:reason;
              delivery_map, Some { path; reason })))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_replay_results_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:reason;
    delivery_map, Some { path; reason }
;;

let remove_base_entries ~base_path map project =
  SMap.filter
    (fun _id value ->
       not (String.equal (project value).audit_base_path base_path))
    map
;;

let merge_loaded_map ~surface ~existing ~loaded =
  SMap.fold
    (fun id value result ->
       match result with
       | Error _ as error -> error
       | Ok map ->
         if SMap.mem id map
         then Error (Printf.sprintf "%s id %s collides with another workspace" surface id)
         else Ok (SMap.add id value map))
    loaded
    (Ok existing)
;;

(* ── Persistent audit log ────────────────────────────────── *)

(* Stdlib.Mutex: the store registry critical section only mutates an in-memory
   hashtable and creates a Dated_jsonl handle. It is also used by synchronous
   tests outside an Eio context, so an Eio mutex would either raise Get_context
   or poison the registry after a recoverable store-creation failure. *)
let approval_sse_pending_event = "approval:pending"
let approval_sse_resolved_event = "approval:resolved"
let approval_sse_summary_event = "approval:summary_updated"

let generate_id () = make_generated_id "appr"

let default_continuation_channel () =
  Keeper_continuation_channel.unrouted "no originating connector"
;;

type approved_delivery_lookup =
  | Approved_delivery_unconsumed of persisted_delivery
  | Approved_delivery_consumed of persisted_delivery

type grant_consumption_commit =
  | Consumption_without_audit of grant_consumption
  | Consumption_with_audit of persisted_delivery

let grant_workspace_mismatch ~base_path approval_id stored_base_path =
  Grant_workspace_mismatch
    { approval_id
    ; requested_base_path = base_path
    ; stored_base_path
    }
;;

let approved_delivery_unlocked ~base_path ~id =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error (Grant_store_unavailable error)
  | None ->
    (match SMap.find_opt id (Atomic.get deliveries) with
     | Some delivery ->
       let stored_base_path = delivery.entry.audit_base_path in
       if not (String.equal stored_base_path base_path)
       then Error (grant_workspace_mismatch ~base_path id stored_base_path)
       else
         (match delivery.decision with
          | Decision.Approve ->
            if delivery.grant_consumed
            then Ok (Approved_delivery_consumed delivery)
            else Ok (Approved_delivery_unconsumed delivery)
          | Decision.Reject _ ->
            Error (Grant_resolution_not_approved id))
     | None ->
       (match SMap.find_opt id (Atomic.get pending) with
        | Some entry ->
          if String.equal entry.audit_base_path base_path
          then Error (Grant_still_pending id)
          else
            Error
              (grant_workspace_mismatch
                 ~base_path
                 id
                 entry.audit_base_path)
        | None -> Error (Grant_resolution_missing id)))
;;

let approved_resolution_request ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_consumed _) -> Ok None
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        (Some
           { keeper_name = delivery.entry.keeper_name
           ; tool_name = delivery.entry.tool_name
           ; input = delivery.entry.input
           }))
;;

let approved_resolution_state ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_consumed _) -> Ok Resolution_consumed
    | Ok (Approved_delivery_unconsumed _) -> Ok Resolution_unconsumed)
;;

let approved_resolution_delivery ~base_path ~id =
  with_pending_store_lock (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        { request =
            { keeper_name = delivery.entry.keeper_name
            ; tool_name = delivery.entry.tool_name
            ; input = delivery.entry.input
            }
        ; state = Resolution_unconsumed
        ; replay_outcome = delivery.replay_outcome
        }
    | Ok (Approved_delivery_consumed delivery) ->
      Ok
        { request =
            { keeper_name = delivery.entry.keeper_name
            ; tool_name = delivery.entry.tool_name
            ; input = delivery.entry.input
            }
        ; state = Resolution_consumed
        ; replay_outcome = delivery.replay_outcome
        })
;;

let resolution_replay_outcome_equal left right =
  match left, right with
  | Replay_applied left, Replay_applied right
  | Replay_applied_with_warning left, Replay_applied_with_warning right
  | Replay_failed left, Replay_failed right
  | Replay_indeterminate left, Replay_indeterminate right ->
    left = right
  | Replay_applied _, Replay_failed _
  | Replay_applied _, Replay_applied_with_warning _
  | Replay_applied _, Replay_indeterminate _
  | Replay_applied_with_warning _, Replay_applied _
  | Replay_applied_with_warning _, Replay_failed _
  | Replay_applied_with_warning _, Replay_indeterminate _
  | Replay_failed _, Replay_applied _
  | Replay_failed _, Replay_applied_with_warning _
  | Replay_failed _, Replay_indeterminate _
  | Replay_indeterminate _, Replay_applied _
  | Replay_indeterminate _, Replay_applied_with_warning _
  | Replay_indeterminate _, Replay_failed _ ->
    false
;;

let record_consumed_resolution_replay ~base_path ~id ~outcome =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get replay_projection_errors) with
    | Some error -> Error (Grant_replay_projection_unavailable error)
    | None ->
      (match approved_delivery_unlocked ~base_path ~id with
       | Error _ as error -> error
       | Ok (Approved_delivery_unconsumed _) ->
         Error (Grant_replay_not_consumed id)
       | Ok (Approved_delivery_consumed delivery) ->
         (match delivery.replay_outcome with
          | Some existing when resolution_replay_outcome_equal existing outcome ->
            Ok Replay_already_recorded
          | Some _ -> Error (Grant_replay_outcome_conflict id)
          | None ->
            let updated_delivery =
              { delivery with replay_outcome = Some outcome }
            in
            let updated_deliveries =
              SMap.add id updated_delivery (Atomic.get deliveries)
            in
            (match
               save_replay_results_file_unlocked
                 ~base_path
                 ~delivery_map:updated_deliveries
             with
             | Error error ->
               Error (Grant_replay_projection_unavailable error)
             | Ok Fsync_completed ->
               Atomic.set deliveries updated_deliveries;
               Ok Replay_recorded
             | Ok (Visible_sync_unconfirmed reason) ->
               let error =
                 { path = replay_results_store_path ~base_path
                 ; reason
                 }
               in
               Error (Grant_replay_projection_unavailable error)))))
;;

let consume_approved_resolution
      ~base_path
      ~id
      ~keeper_name
      ~tool_name
      ~input
  =
  let result =
    with_pending_store_lock (fun () ->
      match approved_delivery_unlocked ~base_path ~id with
      | Error error -> Error error
      | Ok (Approved_delivery_consumed _) ->
        Ok (Consumption_without_audit Consumption_already_committed)
      | Ok (Approved_delivery_unconsumed delivery) ->
        let entry = delivery.entry in
        if
          not
            (String.equal entry.keeper_name keeper_name
             && String.equal entry.tool_name tool_name
             && String.equal
                  entry.input_hash
                  (Keeper_approval_request_fingerprint.request_fingerprint input))
        then Ok (Consumption_without_audit Consumption_not_matching)
        else
          let consumed_delivery = { delivery with grant_consumed = true } in
          let updated_deliveries =
            SMap.add id consumed_delivery (Atomic.get deliveries)
          in
          (match
             persist_snapshot_unlocked
               ~base_path
               ~pending_map:(Atomic.get pending)
               ~delivery_map:updated_deliveries
           with
           | Error error -> Error (Grant_store_unavailable error)
           | Ok () ->
             Atomic.set deliveries updated_deliveries;
             Ok (Consumption_with_audit delivery)))
  in
  match result with
  | Error _ as error -> error
  | Ok (Consumption_without_audit consumption) -> Ok consumption
  | Ok (Consumption_with_audit delivery) ->
    let entry = delivery.entry in
    let audit_receipt =
      Keeper_approval.Audit.record
        ~base_path
        ~event_type:Keeper_approval.Audit.Grant_consumed
        ~id
        ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ?turn_id:entry.turn_id
        ?task_id:entry.task_id
        ?goal_id:entry.goal_id
        ~source_approval_id:id
        ~decision_source:delivery.source
        ~decision:Decision.Approve
        ()
    in
    Ok (Consumption_committed audit_receipt)
;;

let input_preview_of_json (json : Yojson.Safe.t) =
  (* Per-leaf marker-aware truncation: a naive [String.sub] on the
     serialized form would chop a [masc:blob ...] marker mid-field and
     leave sha256/bytes/mime malformed so the approval-queue viewer
     cannot round-trip the preview. *)
  let json = Observability_redact.preview_json_strings ~max_len:200 json in
  let raw = Yojson.Safe.to_string json in
  Observability_redact.redact_preview ~max_len:200 raw
;;

let create_entry
      ~id
      ~sequence
      ~keeper_name
      ~tool_name
      ~input
      ?turn_id
      ?request_context
      ?observation
      ?task_id
      ?goal_id
      ~continuation_channel
      ~audit_base_path
      ()
  =
  let input_hash = Keeper_approval_request_fingerprint.request_fingerprint input in
  { id
  ; keeper_name
  ; tool_name
  ; input_hash
  ; input
  ; sequence
  ; requested_at = Unix.gettimeofday ()
  ; turn_id
  ; request_context
  ; observation
  ; task_id
  ; goal_id
    ; continuation_channel
    ; audit_base_path
    ; summary_status = Summary_not_requested
    ; exact_attempt = Exact_unbound
    ; summary_attempt_disposition = Summary_attempt_ready
    }
;;

let pending_entry_json_fields
      ?(include_input = false)
      (entry : pending_approval)
  =
  [ "id", `String entry.id
  ; "keeper_name", `String entry.keeper_name
  ; "tool_name", `String entry.tool_name
  ; "input_hash", `String entry.input_hash
  ; "sequence", `Int entry.sequence
  ; "requested_at", `Float entry.requested_at
  ; "waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at)
  ; "turn_id", Json_util.int_opt_to_json entry.turn_id
  ; "task_id", Json_util.string_opt_to_json entry.task_id
  ; "goal_id", Json_util.string_opt_to_json entry.goal_id
  ]
  @ (if include_input
     then
       [ "input", entry.input
       ; "input_preview", `String (input_preview_of_json entry.input)
       ]
     else [])
    (* The [include_input] conditional stays parenthesized so the trailing
       canonical [summary_status] field is present in every wire shape. *)
    @ [ "summary_status", summary_status_to_yojson entry.summary_status
      ; "exact_attempt", exact_attempt_state_to_yojson entry.exact_attempt
      ; ( "summary_attempt_disposition"
        , summary_attempt_disposition_to_yojson
            entry.summary_attempt_disposition )
      ; ( "phase"
        , approval_queue_phase_to_yojson
            (phase_of_disposition_and_summary
               ~disposition:entry.summary_attempt_disposition
               ~summary_status:entry.summary_status) )
      ]
;;

let broadcast_pending entry audit_receipt =
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_pending_event
          ; ( "payload"
            , `Assoc
                (pending_entry_json_fields
                   ~include_input:true
                   entry
                 @ [ "audit", Keeper_approval.Audit.receipt_to_yojson audit_receipt ]) )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_pending"
      ~id:entry.id
      ~event_type:(Keeper_approval.Audit.event_to_string Keeper_approval.Audit.Pending)
      exn
;;

let publish_chat_projection_append ~keeper_name = function
  | Error _ as error -> error
  | Ok (Keeper_chat_store.Already_present _) -> Ok ()
  | Ok (Keeper_chat_store.Appended _) ->
    Keeper_chat_broadcast.chat_appended
      ~keeper_name
      ~source:"approval_lifecycle"
      ();
    Ok ()
;;

let append_chat_projection ~base_path ~keeper_name lifecycle =
  Keeper_chat_store.append_approval_lifecycle_once
    ~base_dir:base_path
    ~keeper_name
    ~lifecycle
  |> publish_chat_projection_append ~keeper_name
;;

let record_pending ~call_summary (entry : pending_approval) =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s sequence=%d keeper=%s tool=%s"
    entry.id
    entry.sequence
    entry.keeper_name
    entry.tool_name;
  let audit_receipt =
    Keeper_approval.Audit.record
      ~base_path:entry.audit_base_path
      ~event_type:Keeper_approval.Audit.Pending
      ~id:entry.id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ()
  in
  broadcast_pending entry audit_receipt;
  (* The parked call becomes visible before its answer does. The turn that
     asked keeps running, so without this row the operator sees a tool call
     and then nothing at all until the resolution lands. A projection failure
     is logged and dropped: it must not stop the approval from being queued.
     [call_summary] is the producer's own one-line statement of the call,
     carried on the Gate request; this queue never derives one from the
     input. *)
  (match
     append_chat_projection
       ~base_path:entry.audit_base_path
       ~keeper_name:entry.keeper_name
       { Keeper_chat_store.approval_id = entry.id
       ; tool_name = Some entry.tool_name
       ; phase = Keeper_approval_lifecycle.Approval_requested
       ; artifact_ref = None
       ; call_summary
       }
   with
   | Ok () -> ()
   | Error detail ->
     Log.Keeper.error
       "approval request chat projection failed approval=%s: %s"
       entry.id
       detail);
  audit_receipt
;;

let summary_audit_extras (entry : pending_approval) : (string * Yojson.Safe.t) list =
  match entry.summary_status with
  | Summary_available summary -> [ "model_run_id", `String summary.model_run_id ]
  | Summary_failed { reason } -> [ "failure_reason", `String reason ]
  | Summary_not_requested | Summary_pending -> []
;;

let record_summary_updated ~now (entry : pending_approval) =
  let event_ts =
    match entry.summary_status with
    | Summary_available summary -> summary.generated_at
    | Summary_not_requested | Summary_pending | Summary_failed _ -> now
  in
  ignore
    (Keeper_approval.Audit.record
       ~base_path:entry.audit_base_path
       ~event_type:Keeper_approval.Audit.Summary_updated
       ~id:entry.id
       ~keeper_name:entry.keeper_name
       ~tool_name:entry.tool_name
       ~summary_status:entry.summary_status
       ~exact_attempt:entry.exact_attempt
       ~summary_attempt_disposition:entry.summary_attempt_disposition
       ~timestamp:event_ts
       ~extra_fields:(summary_audit_extras entry)
       ());
  try
    Sse.broadcast
      (`Assoc
         [ "type", `String approval_sse_summary_event
         ; ( "payload"
           , `Assoc
               (pending_entry_json_fields
                  ~include_input:false
                  entry) )
         ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_summary"
      ~id:entry.id
      ~event_type:approval_sse_summary_event
      exn
;;

(* ── Durable summary-state transitions ───────────────────── *)

(** Read a pending entry by id. Returns [None] if already resolved. *)
let find_pending_entry_unchecked ~id : pending_approval option =
  SMap.find_opt id (Atomic.get pending)
;;

let summary_transition_rejection (entry : pending_approval) =
  match entry.exact_attempt with
  | Exact_unbound -> None
  | Exact_bound binding -> Some (Summary_exact_attempt_bound binding)
;;

let persist_pending_entry_unlocked ~map ~(entry : pending_approval) updated_entry =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_unlocked
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error _ as error -> error
  | Ok () ->
    Atomic.set pending updated;
    Ok true
;;

let publish_summary_update ~id =
  let now = Time_compat.now () in
  match find_pending_entry_unchecked ~id with
  | Some updated -> record_summary_updated ~now updated
  | None -> ()
;;

let publish_summary_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let publish_exact_attempt_transition ~id = function
  | Ok ({ changed = true; _ } as transition) ->
    publish_summary_update ~id;
    Ok transition
  | Ok transition -> Ok transition
  | Error error -> Error error
;;

let exact_attempt_entry_unlocked map (candidate : exact_attempt_binding) =
  match SMap.find_opt candidate.approval_id map with
  | None ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_not_found candidate.approval_id))
  | Some entry
    when not
           (String.equal entry.input_hash candidate.input_hash
            && Int.equal entry.sequence candidate.sequence) ->
    Error
      (Exact_attempt_rejected
         (Exact_attempt_key_mismatch
            { approval_id = candidate.approval_id
            ; input_hash = candidate.input_hash
            ; sequence = candidate.sequence
            }))
  | Some entry -> Ok entry
;;

let persist_exact_attempt_entry_unlocked
      ~save_file_atomic_strict_staged
      ~write_mode
      ~changed
      ~map
      ~(entry : pending_approval)
      updated_entry
  =
  let updated = SMap.add entry.id updated_entry map in
  match
    persist_snapshot_exact_unlocked
      ~save_file_atomic_strict_staged
      ~write_mode
      ~base_path:entry.audit_base_path
      ~pending_map:updated
      ~delivery_map:(Atomic.get deliveries)
  with
  | Error error -> Error (Exact_attempt_storage_error error)
  | Ok write_outcome ->
    Atomic.set pending updated;
    Ok { changed; write_outcome }
;;

let bind_summary_exact_attempt_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.bind ~candidate entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let bind_summary_exact_attempt =
  bind_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let release_summary_exact_attempt_before_dispatch_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.release ~candidate entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let release_summary_exact_attempt_before_dispatch =
  release_summary_exact_attempt_before_dispatch_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let quarantine_summary_exact_attempt_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~cause
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.quarantine ~candidate ~cause entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let quarantine_summary_exact_attempt =
  quarantine_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let complete_summary_exact_attempt_with
      ~write_mode
      ~save_file_atomic_strict_staged
      ~id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~summary
  =
  let result =
    match
      validate_exact_attempt_candidate
        ~id
        ~input_hash
        ~sequence
        ~slot_id
        ~call_id
        ~plan_fingerprint
        ~request_body_sha256
    with
    | Error _ as error -> error
    | Ok candidate ->
      with_pending_store_lock (fun () ->
        let map = Atomic.get pending in
        match exact_attempt_entry_unlocked map candidate with
        | Error _ as error -> error
        | Ok entry ->
          (match Keeper_approval_queue_exact_transition.complete ~candidate ~summary entry with
           | Error _ as error -> error
           | Ok transition ->
             persist_exact_attempt_entry_unlocked
               ~save_file_atomic_strict_staged
               ~write_mode
               ~changed:transition.changed
               ~map
               ~entry
               transition.updated_entry))
  in
  publish_exact_attempt_transition ~id result
;;

let complete_summary_exact_attempt =
  complete_summary_exact_attempt_with
    ~write_mode:Append_rows
    ~save_file_atomic_strict_staged:Fs_compat.save_file_atomic_strict_staged
;;

let mark_summary_pending ~id =
  let result =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | None -> Ok false
      | Some entry ->
        (match summary_transition_rejection entry with
         | Some rejection -> Error (Summary_transition_rejected rejection)
         | None ->
           (match entry.summary_status with
            | Summary_not_requested ->
              persist_pending_entry_unlocked
                ~map
                ~entry
                { entry with summary_status = Summary_pending }
              |> Result.map_error (fun error ->
                Summary_transition_storage_error error)
            | Summary_pending
            | Summary_available _
            | Summary_failed _ ->
              Ok false)))
  in
  publish_summary_transition ~id result
;;

let publish_summary_attempt_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      update
  =
  let result =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | None ->
        Error (Exact_attempt_rejected (Exact_attempt_not_found id))
      | Some entry
        when not (String.equal entry.audit_base_path base_path) ->
        Error (Exact_attempt_rejected (Exact_attempt_not_found id))
      | Some entry
        when not
               (String.equal entry.input_hash input_hash
                && Int.equal entry.sequence sequence) ->
        Error
          (Exact_attempt_rejected
             (Exact_attempt_key_mismatch
                { approval_id = id; input_hash; sequence }))
      | Some entry ->
        (match update entry with
         | None -> Ok false
         | Some updated_entry ->
           persist_pending_entry_unlocked
             ~map
             ~entry
             updated_entry
           |> Result.map_error (fun error ->
             Exact_attempt_storage_error error)))
  in
  publish_summary_attempt_transition ~id result
;;

let mark_summary_attempt_identity_unbound
      ~base_path
      ~id
      ~input_hash
      ~sequence
  =
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.exact_attempt,
         entry.summary_attempt_disposition
       with
       | Summary_pending, Exact_unbound,
         ( Summary_attempt_ready
         | Summary_attempt_pre_worker_unavailable
             { reason_code = Summary_pre_worker_start_reserved; _ } ) ->
         Some
           { entry with
             summary_attempt_disposition =
               Summary_attempt_identity_unbound
           }
       | Summary_pending, Exact_unbound,
         Summary_attempt_identity_unbound ->
         Some entry
       | _ -> None)
;;

let mark_summary_attempt_persistence_uncertain
      ~base_path
      ~id
      ~input_hash
      ~sequence
  =
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.summary_attempt_disposition
       with
       | Summary_not_requested, _
       | _, Summary_attempt_persistence_uncertain ->
         None
       | _ ->
         Some
           { entry with
             summary_attempt_disposition =
               Summary_attempt_persistence_uncertain
           })
;;

let mark_summary_attempt_pre_worker_unavailable
      ~base_path
      ~id
      ~input_hash
      ~sequence
      ~reason_code
      ~operator_detail
  =
  let trimmed_detail = String.trim operator_detail in
  if
    String.equal trimmed_detail ""
    || not (String.equal trimmed_detail operator_detail)
  then
    Error
      (Exact_attempt_rejected
         (Exact_attempt_invalid_identity "operator_detail"))
  else
    let blocked =
      Summary_attempt_pre_worker_unavailable
        { reason_code; operator_detail }
    in
    transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      (fun (entry : pending_approval) ->
         match
           entry.summary_status,
           entry.exact_attempt,
           entry.summary_attempt_disposition
         with
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           Summary_attempt_ready ->
           Some
             { entry with
               summary_attempt_disposition = blocked
             }
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           Summary_attempt_pre_worker_unavailable
             { reason_code = Summary_pre_worker_start_reserved; _ } ->
           Some
             { entry with
               summary_attempt_disposition = blocked
             }
         | (Summary_not_requested | Summary_pending), Exact_unbound,
           current
           when current = blocked ->
           Some entry
         | _ -> None)
;;

let release_orphaned_start_reservation ~base_path ~id ~input_hash ~sequence =
  (* Boot-recovery reclaim of a start reservation that a hard process restart
     orphaned. [mark_summary_attempt_pre_worker_unavailable] writes the durable
     [Summary_pre_worker_start_reserved] row; the graceful in-memory settle to
     [Summary_attempt_identity_unbound] (worker terminates before binding) never
     runs when the whole process dies in the reserve->bind window, so the row is
     stranded. This is that arm's exact reverse: an unbound start reservation
     returns to [Summary_attempt_ready] so boot recovery re-activates a worker.
     Distinct from [reserve_summary_attempt_retry], the operator path that never
     reclaims a start reservation. Any other row shape is left untouched. *)
  transition_summary_attempt
    ~base_path
    ~id
    ~input_hash
    ~sequence
    (fun (entry : pending_approval) ->
       match
         entry.summary_status,
         entry.exact_attempt,
         entry.summary_attempt_disposition
       with
       | (Summary_not_requested | Summary_pending), Exact_unbound,
         Summary_attempt_pre_worker_unavailable
           { reason_code = Summary_pre_worker_start_reserved; _ } ->
         Some { entry with summary_attempt_disposition = Summary_attempt_ready }
       | _ -> None)
;;

let reserve_summary_attempt_retry
      ~base_path
      ~id
      ~input_hash
      ~sequence
      ~expected_exact_attempt
      ~expected_disposition
      ~requested_by
  =
  let exact_attempt_state_equal left right =
    match left, right with
    | Exact_unbound, Exact_unbound -> true
    | Exact_bound left, Exact_bound right ->
      exact_attempt_identity_matches left right
      && left.status = right.status
    | Exact_unbound, Exact_bound _
    | Exact_bound _, Exact_unbound ->
      false
  in
  if String.trim requested_by = ""
  then
    Error
      (Exact_attempt_rejected
         (Exact_attempt_invalid_identity "requested_by"))
  else
    let reserved =
      Summary_attempt_pre_worker_unavailable
        { reason_code = Summary_pre_worker_start_reserved
        ; operator_detail = summary_attempt_start_reserved_operator_detail
        }
    in
    transition_summary_attempt
      ~base_path
      ~id
      ~input_hash
      ~sequence
      (fun (entry : pending_approval) ->
         if
           entry.summary_attempt_disposition <> expected_disposition
           || not
                (exact_attempt_state_equal
                   entry.exact_attempt
                   expected_exact_attempt)
         then None
         else
           match
             entry.summary_attempt_disposition,
             entry.exact_attempt,
             entry.summary_status
           with
           | Summary_attempt_identity_unbound, Exact_unbound,
             Summary_pending
           | Summary_attempt_persistence_uncertain, Exact_unbound,
             Summary_pending ->
             Some
               { entry with
                 summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | Summary_attempt_pre_worker_unavailable
               { reason_code =
                   ( Summary_pre_worker_auto_judge_unavailable
                   | Summary_pre_worker_mode_state_invalid )
               ; _
               },
             Exact_unbound,
             (Summary_not_requested | Summary_pending) ->
             Some
               { entry with
                 summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | Summary_attempt_persistence_uncertain,
             Exact_bound
               { status = Exact_released_recovery_required; _ },
             Summary_pending ->
             Some
               { entry with
                 exact_attempt = Exact_unbound
               ; summary_status = Summary_pending
               ; summary_attempt_disposition = reserved
               }
           | _ -> None)
;;

let record_resolution_delivery_failure ~keeper_name ~approval_id reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_approval_queue_failure_site.(to_label Resolution_delivery) )
      ]
    ();
  Log.Keeper.error
    ~keeper_name
    "hitl resolution delivery failed approval=%s: %s"
    approval_id
    reason
;;

let signal_resolution_after_commit ~base_path ~keeper_name ~approval_id =
  try
    let outcome =
      Keeper_registry.wakeup_running
        ~intent:Keeper_registry.Hitl_resolution
        ~base_path
        keeper_name
    in
    let outcome_label, detail =
      match outcome with
      | Keeper_registry.Signaled -> "signaled", "running"
      | Keeper_registry.Deferred_unregistered ->
        "deferred_unregistered", "unregistered"
      | Keeper_registry.Deferred_not_running phase ->
        "deferred_not_running", Keeper_state_machine.phase_to_string phase
      | Keeper_registry.Deferred_lifecycle denial ->
        ( "deferred_lifecycle"
        , Keeper_lifecycle_admission.autonomous_denial_to_wire denial )
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalResolutionSignal)
      ~labels:[ "keeper", keeper_name; "outcome", outcome_label ]
      ();
    Log.Keeper.info
      ~keeper_name
      "hitl resolution committed approval=%s signal=%s phase=%s"
      approval_id
      outcome_label
      detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Resolution_signal)
        ]
      ();
    Log.Keeper.error
      ~keeper_name
      "hitl resolution signal failed after durable commit approval=%s: %s"
      approval_id
      (Printexc.to_string exn)
;;

let commit_keeper_approval_resolution
    ~base_path ~keeper_name ~approval_id ~decision
    ~(channel : Keeper_continuation_channel.t) =
  match
    try
      Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result
        ~base_path
        ~keeper_name
        ~approval_id
        ~decision
        ~channel
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Keeper_registry_event_queue.Hitl_enqueue_failed
           (Printexc.to_string exn))
  with
  | Ok () -> Ok ()
  | Error Keeper_registry_event_queue.Hitl_recipient_absent as error ->
    (* No Keeper exists with the addressed name. That is a terminal
       disposition the caller settles, not a delivery failure, so it gets
       neither the failure counter nor an ERROR log here. *)
    error
  | Error (Keeper_registry_event_queue.Hitl_enqueue_failed reason) as error ->
    record_resolution_delivery_failure ~keeper_name ~approval_id reason;
    error
;;

let hitl_resolution_decision_of_approval_decision = function
  | Decision.Approve -> Keeper_event_queue.Hitl_approved
  | Decision.Reject rationale -> Keeper_event_queue.Hitl_rejected rationale
;;

let deliver_resolution ~base_path (entry : pending_approval) decision =
  commit_keeper_approval_resolution
    ~base_path
    ~keeper_name:entry.keeper_name
    ~approval_id:entry.id
    ~decision:(hitl_resolution_decision_of_approval_decision decision)
    ~channel:entry.continuation_channel
;;

(* Every phase row after the request copies the request row's line. The
   producer stated it once, on the Gate request, and only [record_pending] had
   it in hand; a resolution, replay, or continuation writer has the approval id
   and nothing of the producer, so it reads the stored statement back rather
   than deriving one from the input. [None] when the request row is absent or
   carried none. *)
let requested_call_summary ~base_path ~keeper_name ~approval_id =
  Keeper_chat_store.approval_request_call_summary
    ~base_dir:base_path
    ~keeper_name
    ~approval_id
;;

let ensure_resolution_chat_projection
      ~base_path
      ~keeper_name
      ~approval_id
      ~tool_name
      ~decision
  =
  let phase =
    match decision with
    | Decision.Approve -> Keeper_approval_lifecycle.Approval_resolved_approved
    | Decision.Reject _ -> Keeper_approval_lifecycle.Approval_resolved_rejected
  in
  append_chat_projection
    ~base_path
    ~keeper_name
    { Keeper_chat_store.approval_id
    ; tool_name
    ; phase
    ; artifact_ref = None
    ; call_summary = requested_call_summary ~base_path ~keeper_name ~approval_id
    }
;;

let ensure_replay_chat_projection
      ~base_path
      ~keeper_name
      ~approval_id
      ~tool_name
      ~outcome
  =
  let call_summary = requested_call_summary ~base_path ~keeper_name ~approval_id in
  let phase, artifact_ref =
    match outcome with
    | Replay_applied artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_applied, artifact_ref
    | Replay_applied_with_warning artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_applied_with_warning, artifact_ref
    | Replay_failed artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_failed, artifact_ref
    | Replay_indeterminate artifact_ref ->
      Keeper_approval_lifecycle.Approval_replay_indeterminate, artifact_ref
  in
  Keeper_chat_store.reconcile_approval_replay_lifecycle_once
    ~base_dir:base_path
    ~keeper_name
    ~lifecycle:
      { Keeper_chat_store.approval_id
      ; tool_name
      ; phase
      ; artifact_ref = Some artifact_ref
      ; call_summary
      }
  |> publish_chat_projection_append ~keeper_name
;;

let continuation_settled_chat_projection_present
      ~base_path
      ~keeper_name
      ~approval_id
  =
  Keeper_chat_store.approval_continuation_settled
    ~base_dir:base_path
    ~keeper_name
    ~approval_id
;;

type continuation_projection_result =
  | Continuation_projection_recorded
  | Continuation_projection_not_ready

(* The tool name a continuation receipt names, once the turn had the
   resolution's outcome to show the model: a rejection needs no replay; an
   approval needs its one-shot grant consumed and a durable replay outcome.
   [Ok None] is "not yet": an unconsumed grant, or a consumed grant without
   its outcome, means the effect has not been reported into a turn, so no
   receipt of either phase may settle it. *)
let settled_continuation_tool_name
      ~base_path
      ~(resolution : Keeper_event_queue.hitl_resolution)
  =
  match resolution.decision with
  | Keeper_event_queue.Hitl_rejected _ -> Ok (Some None)
  | Keeper_event_queue.Hitl_approved ->
    (match
       approved_resolution_delivery ~base_path ~id:resolution.approval_id
     with
     | Ok
         { request
         ; state = Resolution_consumed
         ; replay_outcome = Some _
         } ->
       Ok (Some (Some request.tool_name))
     | Ok
         { state = (Resolution_unconsumed | Resolution_consumed)
         ; replay_outcome = None
         ; _
         }
     | Ok
         { state = Resolution_unconsumed
         ; replay_outcome = Some _
         ; _
         } ->
       Ok None
     | Error error -> Error (grant_error_to_string error))
;;

(* The store's answer before it is published: whether the row was appended
   now or was already there decides what the caller logs. *)
type continuation_projection_append =
  | Continuation_appended of Keeper_chat_store.append_once_result
  | Continuation_not_ready

let project_settled_continuation
      ~base_path
      ~keeper_name
      ~(resolution : Keeper_event_queue.hitl_resolution)
      ~phase
  =
  match settled_continuation_tool_name ~base_path ~resolution with
  | Error _ as error -> error
  | Ok None -> Ok Continuation_not_ready
  | Ok (Some tool_name) ->
    let approval_id = resolution.approval_id in
    Result.map
      (fun result -> Continuation_appended result)
      (Keeper_chat_store.append_approval_lifecycle_once
         ~base_dir:base_path
         ~keeper_name
         ~lifecycle:
           { Keeper_chat_store.approval_id
           ; tool_name
           ; phase
           ; artifact_ref = None
           ; call_summary =
               requested_call_summary ~base_path ~keeper_name ~approval_id
           })
;;

let publish_settled_continuation ~keeper_name = function
  | Error _ as error -> error
  | Ok Continuation_not_ready -> Ok Continuation_projection_not_ready
  | Ok (Continuation_appended result) ->
    Result.map
      (fun () -> Continuation_projection_recorded)
      (publish_chat_projection_append ~keeper_name (Ok result))
;;

let ensure_settled_continuation_chat_projection
      ~base_path
      ~keeper_name
      ~(resolution : Keeper_event_queue.hitl_resolution)
  =
  project_settled_continuation
    ~base_path
    ~keeper_name
    ~resolution
    ~phase:Keeper_approval_lifecycle.Approval_continuation_recorded
  |> publish_settled_continuation ~keeper_name
;;

let record_native_continuation_delivery ~base_path ~keeper_name
    ~(resolution : Keeper_event_queue.hitl_resolution) =
  let tool_name = match resolution.decision with
    | Keeper_event_queue.Hitl_rejected _ -> Ok None
    | Keeper_event_queue.Hitl_approved ->
      (match approved_resolution_delivery ~base_path ~id:resolution.approval_id with
       | Ok {request; _} when request.keeper_name = keeper_name -> Ok (Some request.tool_name)
       | Ok _ -> Error "native continuation belongs to another Keeper"
       | Error error -> Error (grant_error_to_string error)) in
  match tool_name with
  | Error detail -> Error detail
  | Ok tool_name ->
    Keeper_chat_store.append_approval_lifecycle_once ~base_dir:base_path ~keeper_name
      ~lifecycle:{ Keeper_chat_store.approval_id=resolution.approval_id; tool_name;
        phase=Keeper_approval_lifecycle.Approval_continuation_recorded; artifact_ref=None;
        call_summary=requested_call_summary ~base_path ~keeper_name ~approval_id:resolution.approval_id }
    |> Result.map (fun appended -> Continuation_appended appended)
    |> publish_settled_continuation ~keeper_name
;;

(* #32956: the turn that received the replay failed after the provider
   answered, so the model has already seen the evidence. The receipt settles
   the continuation slot as failed; the intake then retires the queued wake
   instead of carrying the same evidence into every later cycle. The WARN is
   written once, when the row is appended, and names the route, so a fleet
   grep counts failed continuations by route rather than calls. *)
let ensure_failed_continuation_chat_projection
      ~base_path
      ~keeper_name
      ~(resolution : Keeper_event_queue.hitl_resolution)
      ~(route : Keeper_runtime_failure_route.route)
  =
  let projected =
    project_settled_continuation
      ~base_path
      ~keeper_name
      ~resolution
      ~phase:Keeper_approval_lifecycle.Approval_continuation_failed
  in
  (match projected with
   | Ok (Continuation_appended (Keeper_chat_store.Appended _)) ->
     Log.Keeper.warn
       "HITL_APPROVAL_CONTINUATION_FAILED: id=%s keeper=%s route=%s class=%s"
       resolution.approval_id
       keeper_name
       (Keeper_runtime_failure_route.route_kind_label route)
       (Keeper_runtime_failure_route.route_class_label route)
   | Ok (Continuation_appended (Keeper_chat_store.Already_present _))
   | Ok Continuation_not_ready
   | Error _ -> ());
  publish_settled_continuation ~keeper_name projected
;;

let resolve_entry
      ?(before_terminal_publish = fun () -> ())
      ~base_path
      (entry : pending_approval)
      ~(source : decision_source)
      ?actor
      (decision : decision)
  =
  let decision_str = approval_decision_to_string decision in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id
    entry.keeper_name
    entry.tool_name
    decision_str;
  let audit_receipt =
    Keeper_approval.Audit.record
      ~base_path
      ~event_type:Keeper_approval.Audit.Resolved
      ~id:entry.id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ?actor
      ~decision_source:source
      ~decision
      ~summary_status:entry.summary_status
      ~exact_attempt:entry.exact_attempt
      ()
  in
  before_terminal_publish ();
  (try
     Sse.broadcast
       (`Assoc
           [ "type", `String approval_sse_resolved_event
           ; ( "payload"
             , `Assoc
                 [ "id", `String entry.id
                 ; "keeper_name", `String entry.keeper_name
                 ; "tool_name", `String entry.tool_name
                 ; "decision", `String decision_str
                 ; "audit", Keeper_approval.Audit.receipt_to_yojson audit_receipt
                 ] )
           ])
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     record_queue_failure
       ~keeper_name:entry.keeper_name
       ~site:"broadcast_resolved"
       ~id:entry.id
       ~event_type:(Keeper_approval.Audit.event_to_string Keeper_approval.Audit.Resolved)
       exn);
  audit_receipt
;;

(* ── Nonblocking submission ───────────────────────────────── *)

let submit_pending
      ~keeper_name
      ~tool_name
      ~input
      ~call_summary
      ~base_path
      ?turn_id
      ?request_context
      ?observation
      ?task_id
      ?goal_id
      ?continuation_channel
      ()
  : (pending_submission, storage_error) result
  =
  let input_hash = Keeper_approval_request_fingerprint.request_fingerprint input in
  let continuation_channel =
    Option.value continuation_channel ~default:(default_continuation_channel ())
  in
  let stored =
    with_pending_store_lock (fun () ->
      let map = Atomic.get pending in
      match next_sequence_lifecycle ~base_path with
      | Uninstalled ->
        Error
          { path = pending_store_path ~base_path
          ; reason =
              "gate_pending store is not installed; submit requires a completed install"
          }
      | Unavailable error -> Error error
      | Ready sequence ->
        (match
           find_pending_id_in_map
             map
             ~base_path
             ~keeper_name
             ~tool_name
             ~input_hash
             ~task_id
             ~goal_id
             ~continuation_channel
         with
         | Some id -> Ok (`Deduplicated id)
         | None ->
           (match
              find_unconsumed_grant_id_in_deliveries
                (Atomic.get deliveries)
                ~base_path
                ~keeper_name
                ~tool_name
                ~input_hash
                ~task_id
                ~goal_id
                ~continuation_channel
            with
            | Some id -> Ok (`Folded_onto_unconsumed_grant id)
            | None ->
           let id = generate_id () in
           if sequence = max_int
           then
             Error
               { path = pending_store_path ~base_path
               ; reason = "approval sequence exhausted its integer representation"
               }
           else
             let entry =
               create_entry
                 ~id
                 ~sequence
                 ~keeper_name
                 ~tool_name
                 ~input
                 ?turn_id
              ?request_context
              ?observation
              ?task_id
              ?goal_id
              ~continuation_channel
              ~audit_base_path:base_path
              ()
          in
          let updated = SMap.add id entry map in
          let following_sequence = sequence + 1 in
          (match
             persist_snapshot_with_sequence_unlocked
               ~base_path
               ~next_sequence:following_sequence
               ~pending_map:updated
               ~delivery_map:(Atomic.get deliveries)
           with
           | Error error -> Error error
           | Ok () ->
             Atomic.set pending updated;
             Atomic.set
               next_sequences
               (SMap.add base_path following_sequence (Atomic.get next_sequences));
             Ok (`Created entry)))))
  in
  match stored with
  | Error _ as error -> error
  | Ok (`Deduplicated approval_id) ->
    Ok { approval_id; disposition = Pending_deduplicated }
  | Ok (`Folded_onto_unconsumed_grant approval_id) ->
    Ok { approval_id; disposition = Folded_onto_unconsumed_grant }
  | Ok (`Created entry) ->
    let audit_receipt = record_pending ~call_summary entry in
    Ok
      { approval_id = entry.id
      ; disposition = Pending_created audit_receipt
      }
;;

(* ── Resolve (operator action) ────────────────────────────── *)

type resolve_error =
  | Not_found of string
  | Already_resolved of string
  | Delivery_failed of
      { approval_id : string
      ; reason : string
      }
  | Persistence_failed of
      { approval_id : string
      ; storage_error : storage_error
      }

let resolve_error_to_string = function
  | Not_found id -> Printf.sprintf "approval %s not found" id
  | Already_resolved id -> Printf.sprintf "approval %s already resolved" id
  | Delivery_failed { approval_id; reason } ->
    Printf.sprintf "approval %s resolution delivery failed: %s" approval_id reason
  | Persistence_failed { approval_id; storage_error } ->
    Printf.sprintf
      "approval %s queue persistence failed: %s"
      approval_id
      (storage_error_to_string storage_error)
;;

module Resolution_claims = Set_util.StringSet

let resolution_claims : Resolution_claims.t Atomic.t =
  Atomic.make Resolution_claims.empty
;;

let rec claim_resolution id =
  let claims = Atomic.get resolution_claims in
  if Resolution_claims.mem id claims
  then false
  else
    let claimed = Resolution_claims.add id claims in
    if Atomic.compare_and_set resolution_claims claims claimed
    then true
    else claim_resolution id
;;

let release_resolution_claim id =
  atomic_update resolution_claims (fun claims -> Resolution_claims.remove id claims)
;;

let resolve_store_readiness_error ~base_path ~approval_id =
  match next_sequence_lifecycle ~base_path with
  | Ready _ -> Ok ()
  | Unavailable storage_error ->
    Error (Persistence_failed { approval_id; storage_error })
  | Uninstalled ->
    let storage_error =
      { path = pending_store_path ~base_path
      ; reason =
          "gate_pending store is not installed; resolution requires a completed install"
      }
    in
    Error (Persistence_failed { approval_id; storage_error })
;;

type journal_error =
  | Journal_not_found
  | Journal_storage of storage_error

let journal_resolution ~id ~decision ~source ~remember_rule ~rule_expires_at ~created_by =
  with_pending_store_lock (fun () ->
    let pending_map = Atomic.get pending in
    match SMap.find_opt id pending_map with
    | None -> Error Journal_not_found
    | Some entry ->
      let prepared =
        if remember_rule then
          Keeper_approval_queue_rules.prepare_rule_intent
            ~base_path:entry.audit_base_path ~keeper_name:entry.keeper_name
            ~tool_name:entry.tool_name ~input:entry.input ~operation_id:entry.id
            ~source_approval_id:entry.id ?created_by ?expires_at:rule_expires_at ()
          |> Result.map Option.some
        else Ok None
      in
      match prepared with
      | Error error -> Error (Journal_storage { path = error.path; reason = error.reason })
      | Ok rule_intent ->
      let delivery =
        { entry
        ; decision
        ; source
        ; remember_rule
        ; rule_expires_at
        ; rule_intent
        ; created_by
        ; grant_consumed = false
        ; replay_outcome = None
        }
      in
      let updated_pending = SMap.remove id pending_map in
      let updated_deliveries = SMap.add id delivery (Atomic.get deliveries) in
      (match
         persist_snapshot_unlocked
           ~base_path:entry.audit_base_path
           ~pending_map:updated_pending
           ~delivery_map:updated_deliveries
       with
       | Error storage_error -> Error (Journal_storage storage_error)
       | Ok () ->
         Atomic.set pending updated_pending;
         Atomic.set deliveries updated_deliveries;
         Ok delivery))
;;

let remove_delivery_from_store delivery =
  with_pending_store_lock (fun () ->
    let delivery_map = Atomic.get deliveries in
    let updated_deliveries = SMap.remove delivery.entry.id delivery_map in
    match
      persist_snapshot_unlocked
        ~base_path:delivery.entry.audit_base_path
        ~pending_map:(Atomic.get pending)
        ~delivery_map:updated_deliveries
    with
    | Error _ as error -> error
    | Ok () ->
      Atomic.set deliveries updated_deliveries;
      Ok ())
;;

let approval_decision_equal left right =
  match left, right with
  | Decision.Approve, Decision.Approve -> true
  | Decision.Reject left, Decision.Reject right -> String.equal left right
  | (Decision.Approve | Decision.Reject _),
    (Decision.Approve | Decision.Reject _) ->
    false
;;

let remember_rule_for_delivery delivery =
  match delivery.rule_intent with
  | None -> Ok (None, Rule_not_requested, [])
  | Some intent ->
      match Keeper_approval_queue_rules.apply_rule_intent
          ~base_path:delivery.entry.audit_base_path intent with
      | Error (error : rule_store_error) ->
          Error ({ path = error.path; reason = error.reason } : storage_error)
      | Ok (Keeper_approval_queue_rules.Rule_applied rule) ->
          Ok (Some rule, Rule_saved,
              [ Keeper_approval.Audit.record_rule_created
                  ~base_path:delivery.entry.audit_base_path rule ])
      | Ok (Keeper_approval_queue_rules.Rule_already_applied rule) ->
          Ok (Some rule, Rule_replayed, [])
      | Ok (Keeper_approval_queue_rules.Rule_conflict current) ->
          let revision_json = function None -> `Null | Some value -> `String value in
          let receipt = Keeper_approval.Audit.record
              ~base_path:delivery.entry.audit_base_path
              ~event_type:Keeper_approval.Audit.Rule_conflicted
              ~id:delivery.entry.id ~keeper_name:delivery.entry.keeper_name
              ~tool_name:delivery.entry.tool_name
              ~source_approval_id:delivery.entry.id ?actor:delivery.created_by
              ~extra_fields:[ "expected_revision", revision_json intent.expected_revision;
                "current_revision", revision_json (Keeper_rule_revision.revision current) ] () in
          Ok (None, Rule_conflicted, [receipt])
;;

(* A remembered rule is a separate durable effect from consuming the one-shot
   grant or observing its wake. Reconcile it before either fact can retire the
   delivery. Only authoritative absence permits skipping the rule. *)
let reconcile_delivery_rule delivery =
  match delivery.rule_intent with
  | None -> remember_rule_for_delivery delivery
  | Some _ ->
    let config = Workspace.default_config delivery.entry.audit_base_path in
    (match Keeper_meta_store.read_meta_presence config delivery.entry.keeper_name with
     | Ok Keeper_meta_store.Meta_absent -> Ok (None, Rule_skipped, [])
     | Ok (Keeper_meta_store.Meta_present _) -> remember_rule_for_delivery delivery
     | Error reason ->
       Error { path = pending_store_path ~base_path:delivery.entry.audit_base_path;
               reason = "remembered rule reconciliation: keeper meta: " ^ reason }
     | Ok (Keeper_meta_store.Meta_not_current detail) ->
       Error { path = pending_store_path ~base_path:delivery.entry.audit_base_path;
               reason = "remembered rule reconciliation: keeper meta not current: " ^ detail })
;;

(* A decision is journaled once; wake redelivery does not create another decision. *)
type delivery_occasion = First_commit | Boot_replay | Same_request_resubmitted

let delivery_occasion_to_string = function
  | First_commit -> "first_commit"
  | Boot_replay -> "boot_replay"
  | Same_request_resubmitted -> "same_request_resubmitted"
;;

(* The ledger row and SSE [resolved] for a decision [journal_resolution] has
   just made durable. It runs once per journal, before any wake is attempted,
   so a failed delivery cannot leave the decision off the ledger.

   A failed append does not undo the journal. [Keeper_approval.Audit.record]
   is an observation boundary: its failure is counted and logged there and
   comes back in the receipt, and it must not erase or re-open the
   authoritative decision. The operator's approval stays in force and the
   missing row is visible as an audit append failure, not as a pending
   approval the operator must answer again.

   The chat row is not written here. A delivery whose keeper no longer exists
   is retired without one, and whether the keeper exists is known only when
   the wake is enqueued; [project_resolution_chat] writes it then. *)
let record_journaled_resolution delivery =
  let actor =
    match delivery.created_by with
    | Some actor when String.trim actor <> "" -> Some actor
    | Some _ | None -> None
  in
  resolve_entry
    ~base_path:delivery.entry.audit_base_path
    delivery.entry
    ~source:delivery.source
    ?actor
    delivery.decision
;;

(* The chat row for the decision. [append_approval_lifecycle_once] writes it
   at most once, so every completion that reaches a live keeper may ask for it:
   the one that follows a failed first delivery is the one that writes it. *)
let project_resolution_chat delivery =
  match
    ensure_resolution_chat_projection
      ~base_path:delivery.entry.audit_base_path
      ~keeper_name:delivery.entry.keeper_name
      ~approval_id:delivery.entry.id
      ~tool_name:(Some delivery.entry.tool_name)
      ~decision:delivery.decision
  with
  | Ok () -> ()
  | Error reason ->
    record_resolution_delivery_failure
      ~keeper_name:delivery.entry.keeper_name
      ~approval_id:delivery.entry.id
      ("chat projection: " ^ reason)
;;

let complete_delivery ~(occasion : delivery_occasion) delivery =
  let id = delivery.entry.id in
  let base_path = delivery.entry.audit_base_path in
  (match occasion with
   | First_commit -> ()
   | Boot_replay | Same_request_resubmitted ->
     Log.Keeper.info
       ~keeper_name:delivery.entry.keeper_name
       "hitl resolution redelivered approval=%s occasion=%s"
       id
       (delivery_occasion_to_string occasion));
  match resolve_store_readiness_error ~base_path ~approval_id:id with
  | Error _ as error -> error
  | Ok () ->
    if delivery.grant_consumed
    then (
      (* Consumption suppresses the wake, not the journaled rule mutation. *)
      match reconcile_delivery_rule delivery with
      | Error storage_error -> Error (Persistence_failed { approval_id = id; storage_error })
      | Ok (remembered_rule, remembered_rule_status, audit_receipts) ->
        (match remembered_rule_status with
         | Rule_skipped -> ()
         | Rule_not_requested | Rule_saved | Rule_replayed | Rule_conflicted ->
           project_resolution_chat delivery);
        Ok { remembered_rule; remembered_rule_status; audit_receipts })
    else
      (match deliver_resolution ~base_path delivery.entry delivery.decision with
       | Error Keeper_registry_event_queue.Hitl_recipient_absent ->
         (* No Keeper exists with the addressed name, so this resolution has
            no consumer — ever. The decision is already on the ledger; retire
            the durable delivery, since keeping it would replay the same
            permanent failure at every boot. No always-allow rule and no chat
            row are written: the operator approved a grant for a Keeper that
            is gone. *)
         (match remove_delivery_from_store delivery with
          | Error storage_error ->
            Error (Persistence_failed { approval_id = id; storage_error })
          | Ok () ->
            Log.Keeper.info
              ~keeper_name:delivery.entry.keeper_name
              "hitl delivery retired: no such keeper approval=%s"
              id;
            Ok { remembered_rule = None;
                 remembered_rule_status =
                   (if delivery.remember_rule then Rule_skipped else Rule_not_requested);
                 audit_receipts = [] })
       | Error (Keeper_registry_event_queue.Hitl_enqueue_failed reason) ->
         Error (Delivery_failed { approval_id = id; reason })
       | Ok () ->
         (match reconcile_delivery_rule delivery with
          | Error storage_error ->
            Error (Persistence_failed { approval_id = id; storage_error })
          | Ok (remembered_rule, remembered_rule_status, rule_audit_receipts) ->
            (* Both decisions remain authoritative after their wake is sent.
               A waiting direct operation must re-read the exact rejection as
               well as an approval; the wake alone is not the request store.
               A retained rejection is never a consumable approval grant. *)
            project_resolution_chat delivery;
            signal_resolution_after_commit
              ~base_path
              ~keeper_name:delivery.entry.keeper_name
              ~approval_id:id;
            Ok { remembered_rule; remembered_rule_status; audit_receipts = rule_audit_receipts }))
;;

let delivery_wake_was_observed delivery =
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id = delivery.entry.id
    ; decision =
        hitl_resolution_decision_of_approval_decision delivery.decision
    ; channel = delivery.entry.continuation_channel
    }
  in
  let post_id = Keeper_event_queue.hitl_resolution_post_id resolution in
  match
    Keeper_reaction_ledger.event_queue_delivery_seen_for_source_result
      ~base_path:delivery.entry.audit_base_path
      ~keeper_name:delivery.entry.keeper_name
      ~post_id
      ~stimulus_kind:Keeper_reaction_ledger.Hitl_resolved
  with
  | Ok observed -> observed
  | Error error ->
    Log.Keeper.warn
      ~keeper_name:delivery.entry.keeper_name
      "approval_queue: could not verify prior HITL wake delivery approval=%s; replaying safely: %s"
      delivery.entry.id
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
         error);
    false
;;

(* ── Spent deliveries leave the store at install

   A delivery stays after its wake is sent so the wake's readers can re-read
   the decision. Those readers are: the intake, which reconciles a queued
   [Hitl_resolved] against it; host replay, which records its outcome on it;
   and a direct operation, which observes it while it waits on, binds, or
   resumes from that approval and until it discharges the evidence. Boot
   replay re-sends only a wake that was never delivered, and never for a
   consumed grant. So a delivery is spent when
   - its wake was delivered ([delivery_wake_was_observed], the rule boot
     replay already uses) and is no longer in the Keeper's queue: a delivered
     wake can still be queued, because a turn records its start before the
     queue acknowledges it;
   - no unsettled execution of the Keeper names the approval; and
   - an approval's one-shot grant is consumed (an unconsumed one can still be
     spent by the Keeper; a rejection grants nothing).
   A delivery addressed to a Keeper whose meta is gone is spent too: that is
   the rule [Hitl_recipient_absent] already applies, since nobody can read it.
   The operator's decision and the consumption stay on the audit ledger.
   Without this every approval left a permanent row (2,131 consumed approvals,
   7.8 MB, on 2026-09-23).

   The check runs once per install, the one place that already walks every
   delivery, and before any Keeper starts. Anything that cannot be read -- the
   meta, the queue, the operation store, a Keeper whose queue does not exist
   although its meta does -- keeps the row. *)
type keeper_delivery_readers =
  | Keeper_gone
  | Keeper_readers of
      { queued_wakes : string list
      ; gate_references : string list
      }
  | Keeper_readers_unknown of string

let queued_hitl_wake_ids ~base_path ~keeper_name =
  match
    Keeper_event_queue_persistence.durable_state_exists_result ~base_path ~keeper_name
  with
  | Error reason -> Error reason
  | Ok false -> Error "event queue has no durable state"
  | Ok true ->
    (match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
     | Error reason -> Error reason
     | Ok queue ->
       Ok
         (Keeper_event_queue.to_list queue
          |> List.filter_map (fun (stimulus : Keeper_event_queue.stimulus) ->
            match stimulus.payload with
            | Keeper_event_queue.Hitl_resolved resolution -> Some resolution.approval_id
            | Keeper_event_queue.Board_signal _
            | Keeper_event_queue.Board_attention _
            | Keeper_event_queue.Bootstrap
            | Keeper_event_queue.Fusion_completed _
            | Keeper_event_queue.Schedule_due _
            | Keeper_event_queue.Connector_attention _
            | Keeper_event_queue.Ask_answered _
            | Keeper_event_queue.Completion_authority_rejected _
            | Keeper_event_queue.Task_cancelled _
            | Keeper_event_queue.Workspace_message _
            | Keeper_event_queue.Delegate_completed _
            | Keeper_event_queue.Composition_completed _
            | Keeper_event_queue.Task_outcome _ -> None)))
;;

let gate_references_of_operations ~config ~keeper_name =
  let path =
    Keeper_chat_operation_store.path_for_keeper
      ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_name
  in
  match
    Eio_guard.run_in_systhread ~label:"approval-queue-read" (fun () ->
      Keeper_chat_operation_store.inspect_outstanding ~path)
  with
  | Error error -> Error (Keeper_chat_operation_store.error_to_string error)
  | Ok Keeper_chat_operation_store.Missing_store -> Ok []
  | Ok (Keeper_chat_operation_store.Stored_operations { semantic_executions; chat_operations = _ }) ->
    Ok (List.concat_map Keeper_semantic_execution.gate_approval_ids semantic_executions)
;;

(* Only a missing meta file is a gone Keeper. A file this binary does not
   decode as the current schema ([Meta_not_current]) still names a Keeper: the
   boot path re-materialises it from its declaration after this install, and a
   schema change that makes every live meta not current (a retired key, as in
   #39025) would otherwise retire every Keeper's deliveries at once. *)
let keeper_delivery_readers ~base_path ~keeper_name =
  let config = Workspace.default_config base_path in
  match Keeper_meta_store.read_meta_presence config keeper_name with
  | Error reason -> Keeper_readers_unknown ("keeper meta: " ^ reason)
  | Ok (Keeper_meta_store.Meta_not_current detail) ->
    Keeper_readers_unknown ("keeper meta not current: " ^ detail)
  | Ok Keeper_meta_store.Meta_absent -> Keeper_gone
  | Ok (Keeper_meta_store.Meta_present _) ->
    (match
       ( queued_hitl_wake_ids ~base_path ~keeper_name
       , gate_references_of_operations ~config ~keeper_name )
     with
     | Error reason, _ -> Keeper_readers_unknown ("event queue: " ^ reason)
     | _, Error reason -> Keeper_readers_unknown ("operation store: " ^ reason)
     | Ok queued_wakes, Ok gate_references ->
       Keeper_readers { queued_wakes; gate_references })
;;

let delivery_is_spent readers delivery =
  match readers with
  | Keeper_readers_unknown _ -> false
  | Keeper_gone -> true
  | Keeper_readers { queued_wakes; gate_references } ->
    let id = delivery.entry.id in
    let grant_settled =
      match delivery.decision with
      | Decision.Approve -> delivery.grant_consumed
      | Decision.Reject _ -> true
    in
    grant_settled
    && (not (List.mem id queued_wakes))
    && (not (List.mem id gate_references))
    && delivery_wake_was_observed delivery
;;

let spent_delivery_ids ~base_path loaded_deliveries =
  let readers_by_keeper = Hashtbl.create 8 in
  let readers_of keeper_name =
    match Hashtbl.find_opt readers_by_keeper keeper_name with
    | Some readers -> readers
    | None ->
      let readers = keeper_delivery_readers ~base_path ~keeper_name in
      (match readers with
       | Keeper_gone | Keeper_readers _ -> ()
       | Keeper_readers_unknown reason ->
         Log.Keeper.warn
           ~keeper_name
           "approval_queue: delivery readers unknown; spent deliveries kept: %s"
           reason);
      Hashtbl.add readers_by_keeper keeper_name readers;
      readers
  in
  List.filter_map
    (fun delivery ->
       if delivery_is_spent (readers_of delivery.entry.keeper_name) delivery
       then Some delivery.entry.id
       else None)
    loaded_deliveries
;;

(* The sidecar is written before the snapshot. A crash between the two leaves
   a consumed delivery without its outcome, which the next install retires
   the same way; the other order would leave an outcome whose delivery is
   gone, and that fails the sidecar load. An unreadable sidecar is left
   alone: rewriting it from memory would drop the outcomes it still holds. *)
let retire_spent_deliveries ~base_path ids =
  with_pending_store_lock (fun () ->
    if
      SMap.mem base_path (Atomic.get unavailable_stores)
      || SMap.mem base_path (Atomic.get replay_projection_errors)
    then Ok 0
    else (
      let current = Atomic.get deliveries in
      let retired =
        List.filter
          (fun id ->
             match SMap.find_opt id current with
             | Some delivery -> String.equal delivery.entry.audit_base_path base_path
             | None -> false)
          ids
      in
      match retired with
      | [] -> Ok 0
      | _ :: _ ->
        let updated_deliveries =
          List.fold_left (fun map id -> SMap.remove id map) current retired
        in
        (match save_replay_results_file_unlocked ~base_path ~delivery_map:updated_deliveries with
         | Error error -> Error error
         | Ok (Visible_sync_unconfirmed reason) ->
           Error { path = replay_results_store_path ~base_path; reason }
         | Ok Fsync_completed ->
           (match
              persist_snapshot_unlocked
                ~base_path
                ~pending_map:(Atomic.get pending)
                ~delivery_map:updated_deliveries
            with
            | Error error -> Error error
            | Ok () ->
              Atomic.set deliveries updated_deliveries;
              Ok (List.length retired)))))
;;

let install_persistence_internal ~after_load ~base_path =
  (* Snapshot read and installation are one transition. The hybrid pending
     store lock serializes Eio and non-Eio callers, cooperatively gates Eio
     waiters, and protects cancellation across the durable transition. Keeping
     the load inside this boundary prevents a same-workspace mutation from
     being published between the read and the replacement below. *)
  let installed =
    with_pending_store_lock (fun () ->
      Atomic.set
        pending_read_errors
        (SMap.remove base_path (Atomic.get pending_read_errors));
      let loaded_snapshot =
        match load_snapshot_unlocked ~base_path with
        | Error _ as error -> error
        | Ok
            ( loaded_pending
            , loaded_deliveries
            , loaded_next_sequence
            , pending_read_errors
            , loaded_durable ) ->
          (match loaded_durable with
           | Some durable -> set_durable_state ~base_path durable
           | None -> drop_durable_state ~base_path);
          let loaded_deliveries, replay_projection_error =
            load_replay_results_unlocked
              ~base_path
              ~delivery_map:loaded_deliveries
          in
          Ok
            ( loaded_pending
            , loaded_deliveries
            , loaded_next_sequence
            , replay_projection_error
            , pending_read_errors )
      in
      after_load ();
      match loaded_snapshot with
      | Error storage_error ->
        mark_store_unavailable_unlocked ~base_path storage_error;
        Error storage_error
      | Ok
          ( loaded_pending
          , loaded_deliveries
          , loaded_next_sequence
          , replay_projection_error
          , pending_entry_read_errors ) ->
        let current_pending =
          remove_base_entries ~base_path (Atomic.get pending) Fun.id
        in
        let current_deliveries =
          remove_base_entries
            ~base_path
            (Atomic.get deliveries)
            (fun delivery -> delivery.entry)
        in
        (match
           merge_loaded_map
             ~surface:"gate_pending.pending"
             ~existing:current_pending
             ~loaded:loaded_pending,
           merge_loaded_map
             ~surface:"gate_pending.deliveries"
             ~existing:current_deliveries
             ~loaded:loaded_deliveries
         with
         | Error reason, _ | _, Error reason ->
           let path = pending_store_path ~base_path in
           report_pending_read_drop
             ~reason:Read_drop_reason.Invalid_payload
             ~path
             ~detail:reason;
           let error = { path; reason } in
           mark_store_unavailable_unlocked ~base_path error;
           Error error
         | Ok pending_map, Ok delivery_map ->
           (match first_shared_id pending_map delivery_map with
            | Some id ->
              let path = pending_store_path ~base_path in
              let reason =
                Printf.sprintf
                  "gate_pending id %s collides across pending and delivery states"
                  id
              in
              report_pending_read_drop
                ~reason:Read_drop_reason.Invalid_payload
                ~path
                ~detail:reason;
              let error = { path; reason } in
              mark_store_unavailable_unlocked ~base_path error;
              Error error
            | None ->
              (match pending_entry_read_errors with
               | [] -> clear_store_unavailable_unlocked ~base_path
               | first :: _ -> mark_store_unavailable_unlocked ~base_path first);
              Atomic.set
                pending_read_errors
                (match pending_entry_read_errors with
                 | [] -> SMap.remove base_path (Atomic.get pending_read_errors)
                 | errors -> SMap.add base_path errors (Atomic.get pending_read_errors));
              Atomic.set
                replay_projection_errors
                (match replay_projection_error with
                 | None ->
                   SMap.remove
                     base_path
                     (Atomic.get replay_projection_errors)
                 | Some error ->
                   SMap.add
                     base_path
                     error
                     (Atomic.get replay_projection_errors));
              Atomic.set pending pending_map;
              Atomic.set deliveries delivery_map;
              Atomic.set
                next_sequences
                (SMap.add
                   base_path
                   loaded_next_sequence
                   (Atomic.get next_sequences));
              Ok
                ( SMap.cardinal loaded_pending
                , SMap.bindings loaded_deliveries
                  |> List.map snd
                  |> List.sort (fun left right ->
                    compare_pending_order left.entry right.entry)
                , replay_projection_error ))))
  in
  match installed with
  | Error storage_error -> Error (Install_storage_failed storage_error)
  | Ok (loaded_pending, loaded_deliveries, replay_projection_error) ->
    let rule_failures =
      List.filter_map (fun delivery ->
        let result =
          match resolve_store_readiness_error ~base_path ~approval_id:delivery.entry.id with
          | Error _ as error -> error
          | Ok () ->
            (match reconcile_delivery_rule delivery with
             | Ok _ -> Ok ()
             | Error storage_error ->
               Error (Persistence_failed { approval_id = delivery.entry.id; storage_error })) in
        match result with
        | Ok () -> None
        | Error error -> Some { approval_id = delivery.entry.id;
                                reason = resolve_error_to_string error })
        loaded_deliveries in
    let rule_failed id =
      List.exists (fun failure -> String.equal failure.approval_id id) rule_failures in
    let spent_ids = spent_delivery_ids ~base_path
        (List.filter (fun delivery -> not (rule_failed delivery.entry.id)) loaded_deliveries) in
    let retired_deliveries, delivery_retirement_error, loaded_deliveries =
      match retire_spent_deliveries ~base_path spent_ids with
      | Ok 0 -> 0, None, loaded_deliveries
      | Ok count ->
        ( count
        , None
        , List.filter
            (fun delivery -> not (List.mem delivery.entry.id spent_ids))
            loaded_deliveries )
      | Error error -> 0, Some error, loaded_deliveries
    in
    let rec replay count failures = function
      | [] ->
        Ok
          { loaded_pending
          ; replayed_deliveries = count
          ; delivery_replay_failures = List.rev failures
          ; replay_projection_error
          ; retired_deliveries
          ; delivery_retirement_error
          }
      | delivery :: rest ->
        if rule_failed delivery.entry.id
        then replay count failures rest
        else if delivery.grant_consumed
        then replay count failures rest
        else if delivery_wake_was_observed delivery
        then replay count failures rest
        else
          (match complete_delivery ~occasion:Boot_replay delivery with
           | Ok _ -> replay (count + 1) failures rest
           | Error error ->
             let failure =
               { approval_id = delivery.entry.id
               ; reason = resolve_error_to_string error
               }
             in
             replay count (failure :: failures) rest)
    in
    replay 0 (List.rev rule_failures) loaded_deliveries
;;

let install_persistence ~base_path =
  install_persistence_internal ~after_load:(fun () -> ()) ~base_path
;;

module For_testing = struct
  type strict_snapshot_writer =
    string -> string -> (unit, Fs_compat.atomic_replace_failure) result

  let with_pending_store_lock = with_pending_store_lock
  let get_pending_entry_unchecked = find_pending_entry_unchecked

  let with_unavailable_workspace ~base_path f =
    let previous = with_pending_store_lock (fun () ->
      let stores = Atomic.get unavailable_stores in
      let previous = SMap.find_opt base_path stores in
      Atomic.set unavailable_stores (SMap.add base_path
        {path=base_path; reason="injected unavailable Gate authority"} stores);
      previous) in
    Fun.protect ~finally:(fun () -> with_pending_store_lock (fun () ->
      let stores = Atomic.get unavailable_stores in
      Atomic.set unavailable_stores (match previous with
        | None -> SMap.remove base_path stores
        | Some error -> SMap.add base_path error stores))) f

  let reset_runtime_state () =
    with_pending_store_lock (fun () ->
      Atomic.set pending SMap.empty;
      Atomic.set deliveries SMap.empty;
      Atomic.set unavailable_stores SMap.empty;
      Atomic.set pending_read_errors SMap.empty;
      Atomic.set replay_projection_errors SMap.empty;
      Atomic.set store_revisions SMap.empty;
      Atomic.set next_sequences SMap.empty;
      Atomic.set durable_states SMap.empty)
  ;;

  let install_persistence_with_after_load_hook ~base_path ~after_load =
    install_persistence_internal ~after_load ~base_path
  ;;

  let pending_store_path = pending_store_path
  let replay_results_store_path = replay_results_store_path
  let always_allowed_store_path ~base_path = rules_path ~base_path ()

  (* The injected writer stands in for the snapshot write, so these seams
     rewrite the snapshot on every write instead of appending rows. *)
  let bind_summary_exact_attempt_with_writer =
    bind_summary_exact_attempt_with ~write_mode:Rewrite_snapshot
  ;;

  let release_summary_exact_attempt_before_dispatch_with_writer =
    release_summary_exact_attempt_before_dispatch_with ~write_mode:Rewrite_snapshot
  ;;

  let quarantine_summary_exact_attempt_with_writer =
    quarantine_summary_exact_attempt_with ~write_mode:Rewrite_snapshot
  ;;

  let complete_summary_exact_attempt_with_writer =
    complete_summary_exact_attempt_with ~write_mode:Rewrite_snapshot
  ;;

  let pending_log_path = pending_log_path

  let durable_snapshot_json ~base_path =
    with_pending_store_lock (fun () ->
      match read_durable_unlocked ~base_path with
      | Error error -> Error (storage_error_to_string error)
      | Ok (pending_map, delivery_map, next_sequence, generation, _errors, _log) ->
        Ok
          (snapshot_to_yojson
             ~base_path
             ~next_sequence
             ~generation
             ~pending_map
             ~delivery_map))
  ;;
end

let resolve_with_policy
      ~base_path
      ~id
      ~(decision : decision)
      ~(source : decision_source)
      ?(remember_rule = false)
      ?rule_expires_at
      ?created_by
      ()
  : (resolution_result, resolve_error) result
  =
  match resolve_store_readiness_error ~base_path ~approval_id:id with
  | Error _ as error -> error
  | Ok () ->
    let belongs_to_workspace () =
      match SMap.find_opt id (Atomic.get pending) with
      | Some entry -> String.equal entry.audit_base_path base_path
      | None ->
        (match SMap.find_opt id (Atomic.get deliveries) with
         | Some delivery -> String.equal delivery.entry.audit_base_path base_path
         | None -> false)
    in
    if not (belongs_to_workspace ())
    then Error (Not_found id)
    else if not (claim_resolution id)
    then Error (Already_resolved id)
    else
      Fun.protect
        ~finally:(fun () -> release_resolution_claim id)
        (fun () ->
           if not (belongs_to_workspace ())
           then Error (Not_found id)
           else match SMap.find_opt id (Atomic.get pending) with
           | Some _ ->
             let remember_rule =
               match decision with
               | Decision.Approve -> remember_rule
               | Decision.Reject _ -> false
             in
             let rule_expires_at =
               if remember_rule then rule_expires_at else None
             in
             (match
                journal_resolution
                  ~id
                  ~decision
                  ~source
                  ~remember_rule
                  ~rule_expires_at
                  ~created_by
              with
              | Error Journal_not_found -> Error (Not_found id)
              | Error (Journal_storage storage_error) ->
                Error (Persistence_failed { approval_id = id; storage_error })
              | Ok delivery ->
                let resolution_receipt = record_journaled_resolution delivery in
                (match complete_delivery ~occasion:First_commit delivery with
                 | Error _ as error -> error
                 | Ok result ->
                   Ok
                     { result with
                       audit_receipts =
                         result.audit_receipts @ [ resolution_receipt ]
                     }))
           | None ->
             (match SMap.find_opt id (Atomic.get deliveries) with
              | None -> Error (Not_found id)
              | Some delivery ->
                let same_request =
                  approval_decision_equal decision delivery.decision
                  && source = delivery.source
                  && remember_rule = delivery.remember_rule
                  && rule_expires_at = delivery.rule_expires_at
                  && created_by = delivery.created_by
                in
                if same_request
                then complete_delivery ~occasion:Same_request_resubmitted delivery
                else Error (Already_resolved id)))
;;

(* ── Query ────────────────────────────────────────────────── *)

let retire_summary_owner ~base_path ~keeper_name ~reason =
  let result =
    with_pending_store_lock (fun () ->
      let current = Atomic.get pending in
      let ids, next, bound =
        SMap.fold
          (fun id (entry : pending_approval) (ids, map, bound) ->
             if
               String.equal entry.audit_base_path base_path
               && String.equal entry.keeper_name keeper_name
             then
               match entry.summary_status, entry.exact_attempt with
               | Summary_pending, Exact_bound attempt ->
                 ids, map, Some attempt
               | Summary_pending, Exact_unbound ->
                 ( id :: ids
                 , SMap.add
                     id
                     { entry with
                       summary_status = Summary_failed { reason }
                     }
                     map
                 , bound )
               | ( Summary_not_requested
                 | Summary_available _
                 | Summary_failed _ ),
                 _ ->
                 ids, map, bound
             else ids, map, bound)
          current
          ([], current, None)
      in
      match bound, ids with
      | Some attempt, _ ->
        Error (Summary_owner_retirement_exact_attempt_unsettled attempt)
      | None, [] -> Ok []
      | None, _ ->
        (match
           persist_snapshot_unlocked
             ~base_path
             ~pending_map:next
             ~delivery_map:(Atomic.get deliveries)
         with
         | Error error ->
           Error (Summary_owner_retirement_storage_error error)
         | Ok () ->
           Atomic.set pending next;
           Ok (List.rev ids)))
  in
  match result with
  | Error _ as error -> error
  | Ok ids ->
    List.iter (fun id -> publish_summary_update ~id) ids;
    Ok ids
;;

let pending_entries_in_sequence_order () =
  SMap.fold (fun _id entry acc -> entry :: acc) (Atomic.get pending) []
  |> List.sort compare_pending_order
;;

type pending_entries_snapshot =
  { revision : int
  ; entries : pending_approval list
  ; read_errors : storage_error list
  }

let pending_entries_snapshot_unlocked ~base_path =
  let entries =
    pending_entries_in_sequence_order ()
    |> List.filter (fun (entry : pending_approval) ->
      String.equal entry.audit_base_path base_path)
  in
  let revision = store_revision_unlocked ~base_path in
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some _ when SMap.mem base_path (Atomic.get pending_read_errors) ->
    Ok
      { revision
      ; entries
      ; read_errors =
          Option.value
            (SMap.find_opt base_path (Atomic.get pending_read_errors))
            ~default:[]
      }
  | Some error -> Error error
  | None -> Ok { revision; entries; read_errors = [] }
;;

let pending_entries_snapshot_for_workspace ~base_path =
  with_pending_store_lock (fun () ->
    pending_entries_snapshot_unlocked ~base_path)
;;

let list_pending_entries_with_read_errors_for_workspace ~base_path =
  pending_entries_snapshot_for_workspace ~base_path
  |> Result.map (fun snapshot -> snapshot.entries, snapshot.read_errors)
;;

let list_pending_entries_for_workspace ~base_path =
  list_pending_entries_with_read_errors_for_workspace ~base_path
  |> Result.map fst
;;

let get_pending_entry_for_workspace ~base_path ~id =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get unavailable_stores) with
    | Some error -> Error error
    | None ->
      (match SMap.find_opt id (Atomic.get pending) with
       | Some entry when String.equal entry.audit_base_path base_path ->
         Ok (Some entry)
       | Some _ | None -> Ok None))
;;

let list_pending_dashboard_json_for_workspace ~base_path =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    entries
    |> List.map (fun entry ->
      `Assoc (pending_entry_json_fields ~include_input:true entry)))
;;

let pending_count_for_keeper_in_workspace ~base_path ~keeper_name =
  list_pending_entries_for_workspace ~base_path
  |> Result.map (fun entries ->
    List.fold_left
      (fun count (entry : pending_approval) ->
        if String.equal entry.keeper_name keeper_name then count + 1 else count)
      0
      entries)
;;

type waiting_observation =
  { waiting_request : pending_approval; waiting_decision : decision option }
let observe_waiting_request ~base_path ~id =
  with_pending_store_lock (fun () ->
    match SMap.find_opt base_path (Atomic.get unavailable_stores) with
    | Some error -> Error error
    | None ->
      match SMap.find_opt id (Atomic.get deliveries), SMap.find_opt id (Atomic.get pending) with
      | Some delivery, _ when delivery.entry.audit_base_path = base_path ->
        Ok (Some {waiting_request=delivery.entry; waiting_decision=Some delivery.decision})
      | None, Some entry when entry.audit_base_path = base_path ->
        Ok (Some {waiting_request=entry; waiting_decision=None})
      | Some _, _ | None, Some _ | None, None -> Ok None)
