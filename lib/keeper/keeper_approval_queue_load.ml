open Keeper_approval_queue_rules
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_state
open Keeper_approval_queue_registry
open Keeper_approval_queue_persist

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
    | Error error when Fs_compat.private_jsonl_transaction_error_is_incomplete_tail error ->
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
    match replay_log_lines ~base_path ~snapshot_generation ~pending_map
        ~delivery_map ~next_sequence lines with
    | Error reason -> Error { path; reason }
    | Ok (log_pending, log_deliveries, log_next_sequence, rows_applied) ->
      Ok
        { log_pending
        ; log_deliveries
        ; log_next_sequence
        ; log_end = snapshot.Fs_compat.cursor
        ; rows_applied
        ; partial_tail
        }
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

type loaded_snapshot =
  { loaded_pending : pending_approval SMap.t
  ; loaded_deliveries : persisted_delivery SMap.t
  ; loaded_next_sequence : int
  ; loaded_read_errors : storage_error list
  ; loaded_durable : durable_state option
  }

let load_snapshot_unlocked ~base_path : (loaded_snapshot, storage_error) result =
  let path = pending_store_path ~base_path in
  try
    if not (Sys.file_exists path)
    then
      (* A missing snapshot is a reset store. Rows left in the log describe
         nothing; they are dropped when the first write rewrites both. *)
      Ok
        { loaded_pending = SMap.empty
        ; loaded_deliveries = SMap.empty
        ; loaded_next_sequence = first_sequence
        ; loaded_read_errors = []
        ; loaded_durable = None
        }
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
           let plan =
             plan_restart
               ~pending_map:log.log_pending
               ~delivery_map:log.log_deliveries
               ~entry_errors:pending_entry_errors
               ~partial_tail:log.partial_tail
           in
           let pending_read_errors =
             List.map (fun reason -> { path; reason }) plan.entry_errors
           in
           List.iter
             (fun (error : storage_error) ->
                report_pending_read_drop
                  ~reason:Read_drop_reason.Invalid_payload
                  ~path
                  ~detail:error.reason)
             pending_read_errors;
           let loaded_pending = plan.pending_map in
           let loaded_deliveries = plan.delivery_map in
           let loaded_next_sequence = log.log_next_sequence in
           let durable =
             { durable_pending = loaded_pending
             ; durable_deliveries = loaded_deliveries
             ; snapshot_generation = loaded_generation
             ; log_cursor = log.log_end
             ; log_rows = log.rows_applied
             }
           in
           let loaded loaded_durable =
             { loaded_pending
             ; loaded_deliveries
             ; loaded_next_sequence
             ; loaded_read_errors = pending_read_errors
             ; loaded_durable
             }
           in
           (match plan.rewrite with
           | Rewrite { classification_changed; partial_tail } ->
             let previous_durable = durable_state_for ~base_path in
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
             (match
               compact_unlocked
                 ~write_snapshot
                 ~base_path
                 ~pending_map:loaded_pending
                 ~delivery_map:loaded_deliveries
             with
             | Error _ as error ->
               (match previous_durable with
                | Some prior -> set_durable_state ~base_path prior
                | None -> drop_durable_state ~base_path);
               error
             | Ok (Fsync_completed | Visible_sync_unconfirmed _) ->
               Log.Server.warn
                 "gate_pending restart rewrite workspace=%s classification=%b partial_log_tail=%b"
                 base_path
                 classification_changed
                 partial_tail;
               Ok (loaded (durable_state_for ~base_path)))
           | Retain -> Ok (loaded (Some durable)))
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
