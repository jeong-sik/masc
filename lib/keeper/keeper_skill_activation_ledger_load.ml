open Result.Syntax
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model
open Keeper_skill_activation_ledger_events
open Keeper_skill_activation_ledger_replay

type session_log =
  { ledger : t
  ; cursor : Fs_compat.Private_jsonl_cursor.t
  ; header_written : bool
  }

module Session_logs = Map.Make (String)

(* Keyed by the canonical store path. A store is read and written only under
   its session lock, so one entry never has two writers; the compare-and-set
   loop keeps two sessions' updates from dropping each other. *)
let session_logs : session_log Session_logs.t Atomic.t = Atomic.make Session_logs.empty

let rec update_session_logs change =
  let current = Atomic.get session_logs in
  if not (Atomic.compare_and_set session_logs current (change current))
  then update_session_logs change
;;

let remember_session_log path log = update_session_logs (Session_logs.add path log)
let forget_session_log path = update_session_logs (Session_logs.remove path)
let remembered_session_log path = Session_logs.find_opt path (Atomic.get session_logs)

let observe_settlement_warning ~path error =
  Log.Keeper.error
    "skill_activation_ledger: descriptor settlement incomplete store=%s detail=%s"
    path
    (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let snapshot_result ~path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error -> Error error
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

let cursor_result ~path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error error
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

(* Replay a store from its first byte: on the first read of it in this
   process, and whenever this process no longer knows where the store ends.
   A row a crash left half-appended is cut back to the last complete row
   before anything is replayed. The session lock is held, and every writer
   appends under it, so such a tail was left by a writer that died, never by
   one still writing. A store whose very first row is unterminated is refused
   and left as it is. *)
let replay_session_log ~ownership_root ~expected_trace_id path =
  let* snapshot =
    match
      snapshot_result
        ~path
        (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None)
    with
    | Ok snapshot -> Ok snapshot
    | Error (Fs_compat.Incomplete_transaction_tail _) ->
      (match Fs_compat.load_owned_regular_file ~ownership_root path with
       | Error error -> Error (Read_failed error)
       | Ok (Some contents) when not (starts_with_complete_row contents) ->
         Error (Decode_failed Unterminated_header_row)
       | Ok (Some _ | None) ->
         snapshot_result ~path (Fs_compat.recover_private_jsonl_durable_locked_result path)
         |> Result.map_error (fun error -> Event_log_failed error))
    | Error
        (( Fs_compat.Stable_lock_contended _
         | Fs_compat.Unexpected_stable_lock_permissions _
         | Fs_compat.Invalid_stable_lock_state _
         | Fs_compat.Cursor_mismatch _
         | Fs_compat.Unexpected_transaction_file_kind _
         | Fs_compat.Ambiguous_transaction_file_identity _
         | Fs_compat.Transaction_path_binding_changed _
         | Fs_compat.Transaction_content_changed _
         | Fs_compat.Invalid_transaction_suffix
         | Fs_compat.Private_jsonl_operation_failed _
         | Fs_compat.Rewrite_stage_failed _
         | Fs_compat.Rewrite_published_durability_unknown _
         | Fs_compat.Transaction_settlement_failed _
         | Fs_compat.Transaction_append_failed _ ) as error) ->
      Error (Event_log_failed error)
  in
  let* ledger, header_written =
    replay_store
      ~workspace_root:ownership_root
      ~expected_trace_id
      snapshot.Fs_compat.bytes
    |> Result.map_error (fun error -> Decode_failed error)
  in
  let log = { ledger; cursor = snapshot.Fs_compat.cursor; header_written } in
  remember_session_log path log;
  Ok log
;;

(* Under the session lock. A remembered store is read only after its cursor.
   A failure there drops what this process remembers of the store, and one
   replaced, truncated or left with a torn tail behind that cursor is
   replayed from its first byte at once. *)
let read_locked ~ownership_root ~expected_trace_id session_dir =
  let path = events_path session_dir in
  match remembered_session_log path with
  | None -> replay_session_log ~ownership_root ~expected_trace_id path
  | Some log ->
    (match
       snapshot_result
         ~path
         (Fs_compat.read_private_jsonl_durable_locked_result
            path
            ~after:(Some log.cursor))
     with
     | Error (Fs_compat.Cursor_mismatch _ | Fs_compat.Incomplete_transaction_tail _) ->
       forget_session_log path;
       replay_session_log ~ownership_root ~expected_trace_id path
     | Error
         (( Fs_compat.Stable_lock_contended _
          | Fs_compat.Unexpected_stable_lock_permissions _
          | Fs_compat.Invalid_stable_lock_state _
          | Fs_compat.Unexpected_transaction_file_kind _
          | Fs_compat.Ambiguous_transaction_file_identity _
          | Fs_compat.Transaction_path_binding_changed _
          | Fs_compat.Transaction_content_changed _
          | Fs_compat.Invalid_transaction_suffix
          | Fs_compat.Private_jsonl_operation_failed _
          | Fs_compat.Rewrite_stage_failed _
          | Fs_compat.Rewrite_published_durability_unknown _
          | Fs_compat.Transaction_settlement_failed _
          | Fs_compat.Transaction_append_failed _ ) as error) ->
       forget_session_log path;
       Error (Event_log_failed error)
     | Ok (snapshot : Fs_compat.private_jsonl_snapshot) ->
       if String.equal snapshot.bytes ""
       then Ok log
       else (
         match
           let* rows = complete_rows snapshot.bytes in
           apply_event_rows ~expected_trace_id log.ledger rows
         with
         | Error error ->
           forget_session_log path;
           Error (Decode_failed error)
         | Ok ledger ->
           let log = { log with ledger; cursor = snapshot.cursor } in
           remember_session_log path log;
           Ok log))
;;

let with_lock ~config ~trace_id operation =
  let session_dir =
    Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id)
  in
  match
    Keeper_checkpoint_store.with_session_lock ~session_dir (fun canonical_session_dir ->
      let ownership_root = Filename.dirname canonical_session_dir in
      operation ~ownership_root canonical_session_dir)
  with
  | Error detail -> Error (Lock_failed detail)
  | Ok result -> result
;;

let load ~config ~trace_id =
  with_lock ~config ~trace_id (fun ~ownership_root session_dir ->
    read_locked ~ownership_root ~expected_trace_id:trace_id session_dir
    |> Result.map (fun log -> log.ledger))
;;

(* Without a lock: the store is only ever appended to, so what is on disk is
   a run of committed rows, possibly followed by the row a writer is
   appending right now, which [complete_rows] leaves out. *)
let replay_unlocked ~ownership_root ~trace_id path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error -> Error (Read_failed error)
  | Ok None -> Ok None
  | Ok (Some contents) ->
    (match
       replay_store ~workspace_root:ownership_root ~expected_trace_id:trace_id contents
     with
     | Error error -> Error (Decode_failed error)
     | Ok (_, false) -> Ok None
     | Ok (ledger, true) -> Ok (Some ledger))
;;

let load_existing_read_only_from_root ~ownership_root ~trace_id =
  let session_dir =
    Filename.concat ownership_root (Keeper_id.Trace_id.to_string trace_id)
  in
  replay_unlocked ~ownership_root ~trace_id (events_path session_dir)
;;

(* The header binds the workspace key of the canonical root the writer
   resolves under its lock, so an unlocked reader resolves the same root. *)
let load_existing ~config ~trace_id =
  let session_root =
    Filename.dirname
      (Keeper_fs.keeper_session_dir config (Keeper_id.Trace_id.to_string trace_id))
  in
  match Unix.realpath session_root with
  | exception Unix.Unix_error (cause, _, _) ->
    Error (Canonical_root_failed { path = session_root; cause })
  | ownership_root -> load_existing_read_only_from_root ~ownership_root ~trace_id
;;
