(* See candle_ledger.mli. *)

let file_name = "candle-ledger.jsonl"

let path ~base_path =
  Filename.concat
    (Workspace_utils_paths_backend.masc_dir_from_base_path ~base_path)
    file_name
;;

type view =
  { events : Candle_event.t list
  ; cursor : Fs_compat.Private_jsonl_cursor.t
  }

let events view = view.events

type read_error =
  | Store_failed of
      { path : string
      ; detail : string
      }
  | Row_rejected of
      { path : string
      ; line_number : int
      ; detail : string
      }
  | Locked of { path : string }

let read_error_to_string = function
  | Store_failed { path; detail } ->
    Printf.sprintf "candle ledger %s could not be read: %s" path detail
  | Row_rejected { path; line_number; detail } ->
    Printf.sprintf "candle ledger %s row %d does not read: %s" path line_number detail
  | Locked { path } -> Printf.sprintf "candle ledger %s is locked by another process" path
;;

type 'error update_error =
  | Read_failed of read_error
  | Refused of 'error
  | Event_unwritable of string
  | Write_failed of
      { path : string
      ; detail : string
      }
  | Write_locked of { path : string }

let update_error_to_string refusal_to_string = function
  | Read_failed error -> read_error_to_string error
  | Refused error -> refusal_to_string error
  | Event_unwritable detail ->
    Printf.sprintf "candle ledger event would not read back: %s" detail
  | Write_failed { path; detail } ->
    Printf.sprintf "candle ledger %s could not be written: %s" path detail
  | Write_locked { path } -> Printf.sprintf "candle ledger %s is locked by another process" path
;;

(* The blocking file work runs in a system thread when there is an Eio fiber to
   keep unblocked, and inline when the caller is not under Eio. *)
let run_blocking label operation =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio_unix.run_in_systhread ~label operation
  | exception Effect.Unhandled _ -> operation ()
;;

let store_error = Fs_compat.private_jsonl_transaction_error_to_string

(* How a failure of the cursor family bears on a writer. Every failure is named
   here so that a new one in [Fs_compat] fails to compile until it is placed.
   A lock that another process holds is not a round that another writer
   finished: it can last as long as that process wants, so it is reported and
   never retried in a loop. *)
type contention =
  | Lock_held_by_another_process
  | Appended_meanwhile
  | Other_failure

let contention : Fs_compat.private_jsonl_transaction_error -> contention = function
  | Fs_compat.Stable_lock_contended _ -> Lock_held_by_another_process
  | Fs_compat.Cursor_mismatch _ -> Appended_meanwhile
  | Fs_compat.Unexpected_stable_lock_permissions _
  | Fs_compat.Invalid_stable_lock_state _
  | Fs_compat.Unexpected_transaction_file_kind _
  | Fs_compat.Ambiguous_transaction_file_identity _
  | Fs_compat.Transaction_path_binding_changed _
  | Fs_compat.Incomplete_transaction_tail _
  | Fs_compat.Invalid_transaction_suffix
  | Fs_compat.Private_jsonl_operation_failed _
  | Fs_compat.Rewrite_stage_failed _
  | Fs_compat.Rewrite_published_durability_unknown _
  | Fs_compat.Transaction_settlement_failed _
  | Fs_compat.Transaction_append_failed _ -> Other_failure
;;

let observe_settlement ~path error =
  Log.Misc.warn
    "candle ledger: descriptor settlement incomplete path=%s detail=%s"
    path
    (store_error error)
;;

(* A row is one JSON line. A complete store ends with a newline, so the piece
   after the last one is empty. *)
module Goal_records = Map.Make (String)

let record_goal (event : Candle_event.t) =
  match event.body with
  | Candle_event.Snapshot s -> Some s.goal_id
  | Candle_event.Payout_owed p -> Some p.goal_id
  | Candle_event.Candidates c -> Some c.goal_id
  | Candle_event.Paid p -> Some p.identity.goal_id
  | Candle_event.Unattributed u -> Some u.goal_id
  | Candle_event.Payout_failed f -> Some f.goal_id
  | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ -> None
;;

let remember records event =
  match record_goal event with
  | None -> records
  | Some goal_id ->
    let reversed = match Goal_records.find_opt goal_id records with
      | Some events -> events | None -> [] in
    Goal_records.add goal_id (event :: reversed) records
;;

(* Payout admission depends only on the same Goal's preceding records. Keep
   their file order without rescanning unrelated payouts and purchases. *)
let validate_record records (event : Candle_event.t) =
  let admission = match event.body with
    | Candle_event.Paid _ | Candle_event.Unattributed _ | Candle_event.Payout_failed _ ->
      let preceding = match record_goal event with
        | None -> []
        | Some goal_id ->
          match Goal_records.find_opt goal_id records with
          | None -> [] | Some reversed -> List.rev reversed in
      Candle_payout.validate_record preceding event.body
    | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
    | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ -> Ok () in
  Result.map (fun () -> remember records event) admission
;;

let parse_rows ~path bytes =
  let rec go line_number records acc = function
    | [] | [ "" ] -> Ok (List.rev acc)
    | line :: rest ->
      (match Candle_event.of_line line with
       | Ok event ->
         (match validate_record records event with
          | Ok records -> go (line_number + 1) records (event :: acc) rest
          | Error detail -> Error (Row_rejected { path; line_number; detail }))
       | Error detail -> Error (Row_rejected { path; line_number; detail }))
  in
  go 1 Goal_records.empty [] (String.split_on_char '\n' bytes)
;;

type snapshot_outcome =
  | Snapshot_read of Fs_compat.private_jsonl_snapshot
  | Snapshot_locked
  | Snapshot_failed of string

let snapshot_outcome ~path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error ->
    (match contention error with
     | Lock_held_by_another_process -> Snapshot_locked
     | Appended_meanwhile | Other_failure -> Snapshot_failed (store_error error))
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement ~path) settlement_error;
    Snapshot_read value
;;

let view_of_snapshot ~path (snapshot : Fs_compat.private_jsonl_snapshot) =
  Result.map
    (fun events -> { events; cursor = snapshot.cursor })
    (parse_rows ~path snapshot.bytes)
;;

let view_of_outcome ~path = function
  | Snapshot_read snapshot -> view_of_snapshot ~path snapshot
  | Snapshot_locked -> Error (Locked { path })
  | Snapshot_failed detail -> Error (Store_failed { path; detail })
;;

let read_outcome ~path =
  run_blocking "candle-ledger-read" (fun () ->
    snapshot_outcome
      ~path
      (Fs_compat.read_private_jsonl_durable_locked_result path ~after:None))
;;

let read ~base_path =
  let path = path ~base_path in
  view_of_outcome ~path (read_outcome ~path)
;;

let recover_at_start ~base_path =
  let path = path ~base_path in
  view_of_outcome
    ~path
    (run_blocking "candle-ledger-recover" (fun () ->
       snapshot_outcome ~path (Fs_compat.recover_private_jsonl_durable_locked_result path)))
;;

type append_outcome =
  | Appended
  | Appended_after_another_writer
  | Append_locked
  | Append_failed of string

let append ~path cursor suffix =
  run_blocking "candle-ledger-append" (fun () ->
    match
      Fs_compat.private_jsonl_cursor_success_receipt
        (Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
           path
           ~expected:cursor
           suffix)
    with
    | Ok { Fs_compat.value = _; settlement_error } ->
      Option.iter (observe_settlement ~path) settlement_error;
      Appended
    | Error error ->
      (match contention error with
       | Appended_meanwhile -> Appended_after_another_writer
       | Lock_held_by_another_process -> Append_locked
       | Other_failure -> Append_failed (store_error error)))
;;

let encode ~preceding events =
  let rec go records lines = function
    | [] -> Ok (String.concat "" (List.rev_map (fun line -> line ^ "\n") lines))
    | (event : Candle_event.t) :: rest ->
      let admitted = match event.body with
        | Candle_event.Paid payment -> Candle_payment.validate_for_append payment
        | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
        | Candle_event.Unattributed _ | Candle_event.Payout_failed _
        | Candle_event.Half_life_set _ | Candle_event.Purchased _ | Candle_event.Equipped _ -> Ok () in
      Result.bind admitted (fun () ->
        Result.bind (validate_record records event) (fun records ->
          Result.bind (Candle_event.to_line event) (fun line ->
            go records (line :: lines) rest)))
  in
  go (List.fold_left remember Goal_records.empty preceding) [] events
;;

let rec update ~base_path decide =
  let path = path ~base_path in
  match view_of_outcome ~path (read_outcome ~path) with
  | Error error -> Error (Read_failed error)
  | Ok view ->
    (match decide view with
     | Error error -> Error (Refused error)
     | Ok ([], result) -> Ok result
     | Ok ((_ :: _ as events), result) ->
       (match encode ~preceding:view.events events with
        | Error detail -> Error (Event_unwritable detail)
        | Ok suffix ->
          (match append ~path view.cursor suffix with
           | Appended -> Ok result
           | Appended_after_another_writer -> update ~base_path decide
           | Append_locked -> Error (Write_locked { path })
           | Append_failed detail -> Error (Write_failed { path; detail }))))
;;
