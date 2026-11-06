(** Keeper_msg_async — fire-and-forget keeper message execution.

    Manages background fibers for keeper_msg turns.
    MCP tool returns immediately with a request_id;
    clients poll keeper_msg_result for completion.

    Process memory owns active request workers only. Terminal entries leave the
    active index after a durable namespace move into the terminal partition and
    remain queryable by exact request id until an explicit cleanup policy
    removes them. Startup recovery scans only the active partition; historical
    terminal volume is not on the synchronous recovery path. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

open Result.Syntax

include Keeper_msg_async_types
open Keeper_msg_async_record
include Keeper_msg_async_state
include Keeper_msg_async_locks
include Keeper_msg_async_store
include Keeper_msg_async_recovery
include Keeper_msg_async_lifecycle
include Keeper_msg_async_submit
include Keeper_msg_async_query

let cancel_disk_record ~base_path ~caller ~request_id =
  match load_record_canonical_located ~base_path ~request_id with
  | Located_absent -> Cancel_not_found
  | Located_unreadable reason -> Cancel_unreadable reason
  | Located_rejected rejection -> Cancel_rejected rejection
  | Located (entry, _) ->
    (match owner_rejection ~caller entry with
     | Some rejection -> Cancel_rejected rejection
     | None when is_terminal_status entry.status ->
       Cancel_already_terminal entry.status
     | None ->
       (* Process-local absence is not proof of worker absence: stdio and
          HTTP runtimes can observe the same BasePath. Startup recovery runs
          only under the exclusive server ownership boundary; an arbitrary
          cancel caller must not steal another process's live request. *)
       Cancel_worker_ownership_unknown entry.status)
;;

let signal_operator_cancel ~ops request_sw =
  ops.signal_cancel request_sw CancelledByOperator
;;

let cancel_with_ops ops ~base_path ~caller request_id : cancel_result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Cancel_rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Cancel_rejected Invalid_request_id
    else (
      let key = request_key ~base_path ~submitted_by:caller ~request_id in
      match transition_lock_for_key key with
      | None -> cancel_disk_record ~base_path ~caller ~request_id
      | Some transition_lock ->
        let result =
          Eio.Mutex.use_rw ~protect:true transition_lock (fun () ->
            let current =
              with_lock (fun () ->
                match
                  Request_table.find_opt transition_locks key,
                  Request_table.find_opt pending key
                with
                | None, None -> `Load_disk
                | Some owned, Some entry when owned == transition_lock -> `Entry entry
                | Some _, Some _ ->
                  `Invariant
                    "request transition lock ownership changed during cancellation"
                | Some _, None ->
                  `Invariant
                    "request transition lock exists without an active request entry"
                | None, Some _ ->
                  `Invariant
                    "active request entry exists without its transition lock")
            in
            match current with
            | `Load_disk -> `Load_disk
            | `Invariant reason -> `Result (Cancel_state_invariant_failed { reason })
            | `Entry entry ->
              (match owner_rejection ~caller entry with
               | Some rejection -> `Result (Cancel_rejected rejection)
               | None ->
                 let commit_and_signal cancelling =
                    let persistence =
                      match
                        persist_entry ~ops cancelling
                        |> observe_persist_error ~operation:"operator_cancel" cancelling
                      with
                      | Ok () -> Ok `Durable
                      | Error (Write_failed (Published_uncertain error)) ->
                        Ok
                          (`Volatile
                              (Keeper_fs.durable_write_error_to_string error))
                      | Error ((Write_failed (Not_published _) | Integrity_failed _) as error) ->
                        Error
                          (Cancel_persistence_failed
                             { reason = persist_error_to_string error })
                    in
                    (match persistence with
                     | Error result -> `Result result
                     | Ok durability ->
                       let publication =
                         with_lock (fun () ->
                           match
                             Request_table.find_opt transition_locks key,
                             Request_table.find_opt pending key
                           with
                           | Some owned, Some _ when owned == transition_lock ->
                             Request_table.replace pending key cancelling;
                             `Published (Request_table.find_opt active_switches key)
                           | _ ->
                             `Invariant
                               "request runtime state disappeared after cancellation was published")
                       in
                       let accepted_result =
                         match durability with
                         | `Durable -> Cancellation_requested Durably_committed
                         | `Volatile reason ->
                           Cancellation_requested
                             (Published_unconfirmed { reason })
                       in
                       (match publication with
                        | `Invariant reason ->
                          `Result (Cancel_state_invariant_failed { reason })
                        | `Published None -> `Result accepted_result
                        | `Published (Some request_sw) ->
                          (try
                             signal_operator_cancel ~ops request_sw;
                             `Result accepted_result
                           with
                           | Eio.Cancel.Cancelled _ as e -> raise e
                           | exn ->
                             `Result
                               (Cancel_worker_signal_failed
                                  { durability =
                                      (match durability with
                                       | `Durable -> Durably_committed
                                       | `Volatile reason ->
                                         Published_unconfirmed { reason })
                                  ; reason = Printexc.to_string exn
                                  }))))
                 in
                 (match entry.status with
                  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
                    `Result (Cancel_already_terminal entry.status)
                  | Cancelling _ ->
                    (* The operator's next explicit cancel call is the retry
                       boundary. Re-persist the same intent to recover an exact
                       durability result, then signal the currently owned
                       request switch again. No timer or retry count guesses
                       whether the worker is still live. *)
                    commit_and_signal entry
                  | Queued | Running ->
                    commit_and_signal
                      { entry with
                        status = operator_cancelling_status ()
                      ; completed_at = None
                      }))
              )
        in
        (match result with
         | `Load_disk -> cancel_disk_record ~base_path ~caller ~request_id
         | `Result result -> result))
;;

let cancel = cancel_with_ops production_request_ops

module For_testing = struct
  type nonrec request_ops = request_ops

  let persist_terminal_record (entry : entry) =
    if is_terminal_status entry.status
    then persist_entry ~ops:production_request_ops entry
         |> Result.map_error persist_error_to_string
    else Error "offline request fixture must have a terminal status"
  ;;

  let make_request_ops ?before_durable_write ?before_durable_remove
      ?(generate_request_id = production_request_ops.generate_request_id)
      ?(before_integrity_projection =
        production_request_ops.before_integrity_projection)
      ?(signal_cancel = production_request_ops.signal_cancel) () =
    let save_json_durable =
      match before_durable_write with
      | None -> production_request_ops.save_json_durable
      | Some before_stage ->
        (fun ~ownership_root ~temp_dir path json ->
           Keeper_fs.For_testing.save_json_durable_atomic
             ~before_stage
             ~ownership_root
             ~temp_dir
             path
             json)
    in
    let remove_file_durable =
      match before_durable_remove with
      | None -> production_request_ops.remove_file_durable
      | Some before_stage ->
        (fun ~ownership_root path ->
           Keeper_fs.For_testing.remove_file_durable
             ~before_stage
             ~ownership_root
             path)
    in
    { save_json_durable
    ; remove_file_durable
    ; generate_request_id
    ; before_integrity_projection
    ; signal_cancel
    }
  ;;

  let record_schema_version = record_schema_version
  let is_safe_request_id = is_safe_request_id
  let forget ~base_path ~caller ~request_id =
    match resolve_access_identity ~base_path ~caller with
    | Error rejection ->
      Log.Keeper.warn
        "keeper_msg_async: For_testing.forget rejected request_id=%s error=%s"
        request_id
        (Yojson.Safe.to_string (access_rejection_to_json rejection))
    | Ok (base_path, submitted_by) ->
      let key = request_key ~base_path ~submitted_by ~request_id in
      with_lock (fun () ->
        match Request_table.find_opt transition_locks key with
        | None -> ()
        | Some _ ->
          Store_transition_table.remove
            reserved_request_ids
            ({ base_path; request_id } : Store_transition_key.t);
          Request_table.remove pending key;
          Request_table.remove transition_locks key)
  ;;

  let clear () =
    with_lock (fun () ->
      Request_table.clear pending;
      Request_table.clear transition_locks;
      Request_table.clear active_switches;
      Store_transition_table.clear store_transition_locks;
      Store_transition_table.clear reserved_request_ids;
      Keeper_lane_table.clear keeper_submission_locks;
      Keeper_lane_table.clear keeper_persistence_locks)
  ;;
  let active_record_path = active_record_path
  let terminal_record_path = terminal_record_path
  let atomic_staging_dir = atomic_staging_dir
  let load_record = load_record
  let recover_lost_disk_records = recover_lost_disk_records
  let submit ops ?request_context ?on_accepted ?on_worker_aborted ?on_worker_settled
      ~background_sw ~base_path ~caller ~f ~keeper_name () =
    submit_with_ops ops ?request_context ?on_accepted ?on_worker_aborted
      ?on_worker_settled ~background_sw ~base_path ~caller
      ~f:(fun ~request_id:_ request_sw -> f request_sw)
      ~keeper_name ()
  ;;
  let cancel = cancel_with_ops
  let reserved_request_id_count () =
    Eio.Mutex.use_ro mu (fun () -> Store_transition_table.length reserved_request_ids)
  ;;
  let active_switch_count () =
    Eio.Mutex.use_ro mu (fun () -> Request_table.length active_switches)
  ;;

  let persistence_lane_samples = persistence_lane_samples

end
