(* HIGH-RISK-UNREVIEWED: this module opens, replays, and appends to the files
   of the authorization layer. A line it writes is a grant, revocation, or
   principal that the whole system treats as true, and a line that does not read
   back stops every later start. *)

(* See authz_jsonl_file.mli. *)

type stop =
  { path : string
  ; reason : string
  }

type contents =
  | Missing
  | Empty
  | Lines of int

type tail =
  | Complete
  | Cut of
      { kept_bytes : int
      ; discarded_bytes : int
      }

type recovered =
  { contents : contents
  ; tail : tail
  }

module type Line_format = sig
  type state
  type record
  type line_error
  type reject

  val description : string
  val thread_label : string
  val genesis : state
  val of_line : state -> string -> (record, line_error) result
  val to_line : record -> string
  val equal_record : record -> record -> bool
  val advance : state -> record -> state
  val check_next : state -> record -> (unit, reject) result
  val describe_state : state -> string
  val line_error_to_string : line_error -> string
  val reject_to_string : reject -> string
end

let store_error = Fs_compat.private_jsonl_transaction_error_to_string

(* A completed transaction whose descriptor settlement stayed incomplete has
   still done its work, so the caller goes on and the evidence is logged.
   Settlement is the close of a descriptor after the transaction body returned.
   For an append the body syncs the lines before it returns, and the contract
   of [Fs_compat.private_jsonl_success_receipt] lets a consumer advance from the
   value as long as it observes the error. *)
let observe_settlement ~description ~path error =
  Log.Auth.warn
    "%s: descriptor settlement incomplete path=%s detail=%s"
    description
    path
    (store_error error)
;;

(* How a failure of the cursor family bears on the file. Every failure is named
   here so that a new one in [Fs_compat] fails to compile until it is placed.
   A lock that another process holds wrote nothing and read nothing. A cursor
   that no longer matches means another writer moved the end. Every other
   failure may have left bytes behind, so the file is not known. *)
type failure_kind =
  | Lock_held_by_another_process
  | End_moved
  | Outcome_unknown

let failure_kind : Fs_compat.private_jsonl_transaction_error -> failure_kind = function
  | Fs_compat.Stable_lock_contended _ -> Lock_held_by_another_process
  | Fs_compat.Cursor_mismatch _ -> End_moved
  | Fs_compat.Unexpected_stable_lock_permissions _
  | Fs_compat.Invalid_stable_lock_state _
  | Fs_compat.Unexpected_transaction_file_kind _
  | Fs_compat.Ambiguous_transaction_file_identity _
  | Fs_compat.Transaction_path_binding_changed _
  | Fs_compat.Transaction_content_changed _
  | Fs_compat.Incomplete_transaction_tail _
  | Fs_compat.Invalid_transaction_suffix
  | Fs_compat.Private_jsonl_operation_failed _
  | Fs_compat.Rewrite_stage_failed _
  | Fs_compat.Rewrite_published_durability_unknown _
  | Fs_compat.Transaction_settlement_failed _
  | Fs_compat.Transaction_append_failed _ -> Outcome_unknown
;;

(* The size the file has before the cut, to tell how much of it the cut took.
   A missing file has no bytes. It is read before the lock is taken, so it is
   exact only while no other process writes the file, which the server that
   opens the file guarantees (see the interface). *)
let size_of_file ~path =
  match Unix.stat path with
  | stats -> Ok stats.Unix.st_size
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok 0
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
;;

let contents_of ~missing ~line_count =
  if missing then Missing else if line_count = 0 then Empty else Lines line_count
;;

(* A size that is not larger than the bytes kept is reported as no cut. A file
   that grew between the stat and the lock, which only a second writer causes,
   gives a difference of zero or less, and then a cut that really happened goes
   unreported. The append of the process that wrote second returns [Diverged]. *)
let tail_of ~size_before ~kept_bytes =
  let discarded_bytes = size_before - kept_bytes in
  if discarded_bytes > 0 then Cut { kept_bytes; discarded_bytes } else Complete
;;

(* Why a file refuses appends once the end of it has moved. A write that fails
   in a way that leaves the file unknown stops the file with the text of its
   failure. An exception that leaves a write unfinished needs no flag: the next
   append names the end it expects, and [Fs_compat] refuses it if the write
   moved the end. *)
let end_moved = "the end of the file is not where this process left it"

type 'a zone_outcome =
  | Entered of 'a
  | Refused of stop
  | Raised of exn * Printexc.raw_backtrace

module Make (F : Line_format) = struct
  type t =
    { path : string
    ; zone : Eio.Mutex.t
    ; mutable head : F.state
    ; mutable cursor : Fs_compat.Private_jsonl_cursor.t
    ; mutable stopped : string option
    }

  type writer =
    { log : t
    ; mutable live : bool
    }

  type 'reason open_error =
    | Locked of { path : string }
    | Unreadable of
        { path : string
        ; detail : string
        }
    | Line_rejected of
        { path : string
        ; line_number : int
        ; error : F.line_error
        }
    | Fold_refused of
        { path : string
        ; line_number : int
        ; reason : 'reason
        }

  type append_error =
    | Writer_expired
    | Stopped of stop
    | Rejected of
        { index : int
        ; reject : F.reject
        }
    | Would_not_read_back of
        { index : int
        ; error : F.line_error
        }
    | Read_back_changed of { index : int }
    | Write_locked of { path : string }
    | Diverged of { path : string }
    | Write_failed of
        { path : string
        ; detail : string
        }

  let stopped (log : t) =
    Option.map (fun reason -> { path = log.path; reason }) log.stopped
  ;;

  let open_error_to_string reason_to_string = function
    | Locked { path } ->
      Printf.sprintf "%s %s is locked by another process" F.description path
    | Unreadable { path; detail } ->
      Printf.sprintf "%s %s cannot be read: %s" F.description path detail
    | Line_rejected { path; line_number; error } ->
      Printf.sprintf
        "%s %s line %d is not the next line: %s"
        F.description
        path
        line_number
        (F.line_error_to_string error)
    | Fold_refused { path; line_number; reason } ->
      Printf.sprintf
        "%s %s line %d was refused by the caller: %s"
        F.description
        path
        line_number
        (reason_to_string reason)
  ;;

  (* Reads the file as the recovery read of [Fs_compat] does, which is the only
     read that cuts a last line that never ended. Process start is the one caller the
     contract of [Fs_compat] allows. *)
  let read_for_recovery ~path =
    match size_of_file ~path with
    | Error detail -> Error (Unreadable { path; detail })
    | Ok size_before ->
      (match
         Fs_compat.private_jsonl_snapshot_success_receipt
           (Fs_compat.recover_private_jsonl_durable_locked_result path)
       with
       | Ok { Fs_compat.value = snapshot; settlement_error } ->
         Option.iter (observe_settlement ~description:F.description ~path) settlement_error;
         Ok (snapshot, size_before)
       | Error error ->
         (match failure_kind error with
          | Lock_held_by_another_process -> Error (Locked { path })
          | End_moved | Outcome_unknown ->
            Error (Unreadable { path; detail = store_error error })))
  ;;

  (* Checks the lines of a complete store one by one against the state before
     them and folds them. [Fs_compat] returns only complete rows, so every line
     ends in a newline. *)
  let replay ~path ~init ~step bytes =
    let length = String.length bytes in
    let rec go line_number offset head state =
      if offset >= length
      then Ok (state, head, line_number - 1)
      else (
        match String.index_from_opt bytes offset '\n' with
        | None ->
          Error (Unreadable { path; detail = "the last row of the store has no newline" })
        | Some stop ->
          let line = String.sub bytes offset (stop - offset) in
          (match F.of_line head line with
           | Error error -> Error (Line_rejected { path; line_number; error })
           | Ok record ->
             (match step state record with
              | Error reason -> Error (Fold_refused { path; line_number; reason })
              | Ok state -> go (line_number + 1) (stop + 1) (F.advance head record) state)))
    in
    go 1 0 F.genesis init
  ;;

  let open_on_thread ~path ~init ~step =
    Result.bind
      (read_for_recovery ~path)
      (fun (snapshot, size_before) ->
        let bytes = snapshot.Fs_compat.bytes in
        Result.map
          (fun (state, head, line_count) ->
            let tail = tail_of ~size_before ~kept_bytes:(String.length bytes) in
            let contents =
              contents_of
                ~missing:(Fs_compat.Private_jsonl_cursor.is_missing snapshot.Fs_compat.cursor)
                ~line_count
            in
            state, head, snapshot.Fs_compat.cursor, { contents; tail })
          (replay ~path ~init ~step bytes))
  ;;

  let open_at_start ~path ~init ~step =
    match
      Systhread_host.run ~label:(F.thread_label ^ "-open") (fun () ->
        open_on_thread ~path ~init ~step)
    with
    | Error error -> Error error
    | Ok (state, head, cursor, recovered) ->
      (match recovered.tail with
       | Complete -> ()
       | Cut { kept_bytes; discarded_bytes } ->
         Log.Auth.warn
           "%s %s: cut %d bytes of a last line that never ended, kept %d bytes, %s"
           F.description
           path
           discarded_bytes
           kept_bytes
           (F.describe_state head));
      Ok ({ path; zone = Eio.Mutex.create (); head; cursor; stopped = None }, state, recovered)
  ;;

  let append_error_to_string = function
    | Writer_expired -> "the zone of this writer has ended"
    | Stopped { path; reason } ->
      Printf.sprintf "%s %s is stopped: %s" F.description path reason
    | Rejected { index; reject } ->
      Printf.sprintf "record %d was refused: %s" index (F.reject_to_string reject)
    | Would_not_read_back { index; error } ->
      Printf.sprintf "record %d would not read back: %s" index (F.line_error_to_string error)
    | Read_back_changed { index } ->
      Printf.sprintf "record %d reads back as a different record" index
    | Write_locked { path } ->
      Printf.sprintf "%s %s is locked by another process" F.description path
    | Diverged { path } ->
      Printf.sprintf "%s %s does not end where this process left it" F.description path
    | Write_failed { path; detail } ->
      Printf.sprintf "%s %s could not be written: %s" F.description path detail
  ;;

  (* The lines to write and the state after them, or the first record that
     does not continue the file. Each line is read back against the state it
     would have in the file, and must give the record that was written: the
     state after the append is the state the next start computes. *)
  let encode ~head records =
    let rec go index head lines = function
      | [] -> Ok (List.rev lines, head)
      | record :: rest ->
        (match F.check_next head record with
         | Error reject -> Error (Rejected { index; reject })
         | Ok () ->
           let line = F.to_line record in
           (match F.of_line head line with
            | Error error -> Error (Would_not_read_back { index; error })
            | Ok read_back when F.equal_record record read_back ->
              go (index + 1) (F.advance head record) (line :: lines) rest
            | Ok _ -> Error (Read_back_changed { index })))
    in
    go 0 head [] records
  ;;

  (* The thread gets the path and the cursor as values, so it reads no field that
     the zone changes. *)
  let write_on_thread (log : t) payload =
    let path = log.path
    and expected = log.cursor in
    Systhread_host.run ~label:(F.thread_label ^ "-append") (fun () ->
      Fs_compat.private_jsonl_cursor_success_receipt
        (Fs_compat.append_private_jsonl_durable_locked_at_cursor_result path ~expected payload))
  ;;

  let write (log : t) ~head payload =
    match write_on_thread log payload with
    | exception exn ->
      (* The lines may or may not be in the file, and the state and the cursor
         stay where they were. The file stops, so that no caller reads the state
         as if it were current. The exception goes on to the caller. *)
      let backtrace = Printexc.get_raw_backtrace () in
      log.stopped
      <- Some
           (Printf.sprintf
              "a write raised %s, so the end of the file is not known"
              (Printexc.to_string exn));
      Printexc.raise_with_backtrace exn backtrace
    | Ok { Fs_compat.value = cursor; settlement_error } ->
      Option.iter (observe_settlement ~description:F.description ~path:log.path) settlement_error;
      log.head <- head;
      log.cursor <- cursor;
      Ok head
    | Error error ->
      (match failure_kind error with
       | Lock_held_by_another_process -> Error (Write_locked { path = log.path })
       | End_moved ->
         log.stopped <- Some end_moved;
         Error (Diverged { path = log.path })
       | Outcome_unknown ->
         let detail = store_error error in
         log.stopped <- Some detail;
         Error (Write_failed { path = log.path; detail }))
  ;;

  let append writer records =
    let log = writer.log in
    if not writer.live
    then Error Writer_expired
    else (
      match log.stopped with
      | Some reason -> Error (Stopped { path = log.path; reason })
      | None ->
        Result.bind (encode ~head:log.head records) (fun (lines, head) ->
          match lines with
          | [] -> Ok head
          | _ :: _ ->
            write log ~head (String.concat "" (List.map (fun line -> line ^ "\n") lines))))
  ;;

  (* [Eio.Mutex.use_rw] disables the mutex for good when its function raises.
     That would turn any exception of the caller's, even one that never touched
     the file, into a file that cannot be entered again. What the file holds is
     kept consistent by the cursor and by [stopped], so the exception is carried
     out of the critical section and raised after the mutex is released. A stop
     that happened while this fiber waited is seen only after the zone is its
     own. *)
  let with_writer (log : t) f =
    let outcome =
      Eio.Mutex.use_rw ~protect:true log.zone (fun () ->
        match log.stopped with
        | Some reason -> Refused { path = log.path; reason }
        | None ->
          let writer = { log; live = true } in
          (match f writer log.head with
           | result ->
             writer.live <- false;
             Entered result
           | exception exn ->
             let backtrace = Printexc.get_raw_backtrace () in
             writer.live <- false;
             Raised (exn, backtrace)))
    in
    match outcome with
    | Entered result -> Ok result
    | Refused stop -> Error stop
    | Raised (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
  ;;
end
