open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_state
open Keeper_approval_queue_registry

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
         | (Error
              ( Fs_compat.Invalid_transaction_suffix
              | Fs_compat.Stable_lock_contended _
              | Fs_compat.Unexpected_stable_lock_permissions _
              | Fs_compat.Invalid_stable_lock_state _
              | Fs_compat.Unexpected_transaction_file_kind _
              | Fs_compat.Ambiguous_transaction_file_identity _
              | Fs_compat.Transaction_path_binding_changed _
              | Fs_compat.Transaction_content_changed _
              | Fs_compat.Incomplete_transaction_tail _
              | Fs_compat.Private_jsonl_operation_failed _
              | Fs_compat.Rewrite_stage_failed _
              | Fs_compat.Rewrite_published_durability_unknown _
              | Fs_compat.Transaction_settlement_failed _
              | Fs_compat.Transaction_append_failed _ )
           | Ok _) as appended ->
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
