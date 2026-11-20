module Current = Keeper_memory_os_current_types
module Digest = Agent_core.Checkpoint_objects
module Snapshot_codec = Keeper_memory_os_snapshot_codec
module Envelope = Librarian_envelope
module Log = Librarian_log
module Log_store = Librarian_log_store
module Turn_store = Keeper_turn_log_store

type stop =
  | Log_diverged of
      { expected : Digest.digest
      ; observed : Digest.digest
      }
  | Memory_unreadable
  | Log_unreadable
  | Store_unwritable

type t =
  { log_path : string
  ; snapshot_path : string
  ; log_end : int
  ; tail : Log.line
  ; memory : Current.t
  ; digest : Digest.digest
  }

let memory t = t.memory
let tail t = t.tail
let same (a : Digest.digest) (b : Digest.digest) = String.equal (a :> string) (b :> string)

(* The snapshot a line says is on disk after it. *)
let named : Log.line -> Digest.digest = function
  | Started { snapshot; _ } -> snapshot
  | Committed { after; _ } -> after
;;

let encoded line = Yojson.Safe.to_string (Librarian_log_codec.to_json line)

module Snapshot_fault = Librarian_snapshot_fault

(* What the snapshot path holds. A read that failed says nothing about the
   file: it is not "no snapshot". *)
let read_bytes path : (string, Snapshot_fault.t) result =
  match Fs_compat.load_regular_file_opt path with
  | Ok None -> Error Snapshot_fault.Absent
  | Ok (Some bytes) -> Ok bytes
  | Error (Fs_compat.Not_a_regular_file (_ : Unix.file_kind)) ->
    Error Snapshot_fault.Not_a_snapshot_file
  | Error (Fs_compat.Regular_file_unreadable (_ : string)) -> Error Snapshot_fault.Not_read
;;

let decoded bytes =
  match Yojson.Safe.from_string bytes with
  | exception Yojson.Json_error (_ : string) -> None
  | json ->
    (match Snapshot_codec.of_json json with
     | Error (_ : Snapshot_codec.snapshot_rejection) -> None
     | Ok memory -> Some memory)
;;

(* The digest is of the bytes the file holds, not of the bytes the codec
   would write for what they decode to. *)
let read_snapshot path =
  match read_bytes path with
  | Error fault -> Error fault
  | Ok bytes ->
    (match decoded bytes with
     | None -> Error Snapshot_fault.Not_a_snapshot_file
     | Some memory -> Ok (memory, Digest.digest_of_bytes bytes))
;;

let stop_of_snapshot_fault : Snapshot_fault.t -> stop = function
  | Absent | Not_a_snapshot_file -> Memory_unreadable
  | Not_read -> Store_unwritable
;;

let write_snapshot path bytes =
  match Fs_compat.mkdir_p (Filename.dirname path) with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception (_ : exn) -> Error ()
  | () ->
    (match Fs_compat.save_file_atomic_strict path bytes with
     | Ok () -> Ok ()
     | Error (_ : string) -> Error ())
;;

(* [Started] names the turn log, and the writer does not make that file. *)
let turn_log_start turn_log_path =
  match Turn_store.read_start turn_log_path with
  | Ok (Some start) -> Ok start
  | Ok None
  | Error
      (Turn_store.Read_failed _ | Row_undecodable _ | Log_start_missing | Moved_while_reading)
    -> Error Store_unwritable
;;

(* The line that starts reading the turn log from its first line. *)
let started ~at ~(start : Turn_store.start) ~(memory : Current.t) ~digest =
  Log.Started
    { at
    ; turn_log = start.id
    ; snapshot = digest
    ; revision = memory.revision
    ; turn_log_offset = 0
    ; covered = start.mark
    }
;;

let first_boot ~log_path ~snapshot_path ~turn_log_path ~at =
  let ( let* ) = Result.bind in
  let* start = turn_log_start turn_log_path in
  let* memory, digest =
    match read_snapshot snapshot_path with
    | Ok found -> Ok found
    | Error Snapshot_fault.Absent ->
      let memory = Envelope.empty ~at ~turn_log:start.id in
      let bytes = Snapshot_codec.snapshot_bytes memory in
      (match write_snapshot snapshot_path bytes with
       | Ok () -> Ok (memory, Digest.digest_of_bytes bytes)
       | Error () -> Error Store_unwritable)
    | Error ((Not_a_snapshot_file | Not_read) as fault) -> Error (stop_of_snapshot_fault fault)
  in
  let line = started ~at ~start ~memory ~digest in
  match Log_store.append ~path:log_path ~at_end:0 line with
  | Ok { new_end; at = (_ : int) } ->
    Ok { log_path; snapshot_path; log_end = new_end; tail = line; memory; digest }
  | Error (Log_store.End_moved _ | Directory_unavailable _ | Write_failed _) ->
    Error Store_unwritable
;;

let recover ~log_path ~snapshot_path ~log_end ~(tail : Log.line) =
  match read_snapshot snapshot_path with
  | Error fault -> Error (stop_of_snapshot_fault fault)
  | Ok (memory, observed) ->
    let expected = named tail in
    let diverged = Error (Log_diverged { expected; observed }) in
    if same observed expected
    then Ok { log_path; snapshot_path; log_end; tail; memory; digest = observed }
    else (
      match tail with
      | Started _ -> diverged
      | Committed commit when not (same observed commit.basis) -> diverged
      | Committed commit ->
        (* The line is on disk and its snapshot is not: write it from the
           line. *)
        (match Envelope.after ~previous:memory commit with
         | Error (_ : Envelope.refusal) | Ok Unchanged -> diverged
         | Ok (Rewritten { snapshot = next; bytes }) ->
           let digest = Digest.digest_of_bytes bytes in
           if not (same digest expected)
           then diverged
           else (
             match write_snapshot snapshot_path bytes with
             | Ok () -> Ok { log_path; snapshot_path; log_end; tail; memory = next; digest }
             | Error () -> Error Store_unwritable)))
;;

let boot ~memory_dir ~turns_dir ~keeper_id ~at =
  let log_path = Log_store.path_for_keepers_dir ~keepers_dir:memory_dir ~keeper_id in
  let snapshot_path =
    Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:memory_dir ~keeper_id
  in
  match Log_store.read_tail log_path with
  | Error (Log_store.Tail_undecodable _) -> Error Log_unreadable
  | Error (Read_failed _ | Moved_while_reading) -> Error Store_unwritable
  | Ok Nothing_written ->
    let turn_log_path = Turn_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id in
    first_boot ~log_path ~snapshot_path ~turn_log_path ~at
  | Ok (Written { rows_end; last; last_at = (_ : int) }) ->
    recover ~log_path ~snapshot_path ~log_end:rows_end ~tail:last
;;

type committed =
  | Committed of
      { store : t
      ; line : Log.commit
      }
  | Committed_without_snapshot of Log.commit
  | Stopped of stop
  | Not_a_snapshot of Envelope.refusal

let first_seq = 1

(* A line that does not move what was read carries the reading position and
   the working state of the line before it. *)
let line_after (tail : Log.line) ~at ~basis ~after ~revision ~cause ~effects : Log.commit =
  match tail with
  | Started { turn_log; turn_log_offset; covered; _ } ->
    { seq = first_seq
    ; at
    ; basis
    ; after
    ; revision
    ; cause
    ; effects
    ; turn_log
    ; turn_log_offset
    ; covers_through = Before_first
    ; covered
    ; working_state = None
    }
  | Committed previous ->
    { previous with seq = previous.seq + 1; at; basis; after; revision; cause; effects }
;;

(* The error of an append does not say whether the line is on disk: a write
   whose undo failed can leave it there. The tail does. *)
let append t (line : Log.commit) =
  match Log_store.append ~path:t.log_path ~at_end:t.log_end (Committed line) with
  | Ok { new_end; at = (_ : int) } -> Ok new_end
  | Error (Log_store.End_moved _ | Directory_unavailable _ | Write_failed _) ->
    (match Log_store.read_tail t.log_path with
     | Error (Log_store.Tail_undecodable _) -> Error Log_unreadable
     | Error (Read_failed _ | Moved_while_reading) -> Error Store_unwritable
     | Ok Nothing_written -> Error (Log_diverged { expected = t.digest; observed = t.digest })
     | Ok (Written { rows_end; last; last_at = (_ : int) }) ->
       let landed =
         match last with
         | Committed found -> Int.equal found.seq line.seq && same found.after line.after
         | Started _ -> false
       in
       if landed
       then Ok rows_end
       else if Int.equal rows_end t.log_end && String.equal (encoded last) (encoded t.tail)
       then Error Store_unwritable
       else Error (Log_diverged { expected = named last; observed = t.digest }))
;;

let commit_direct t ~at ~by ~trace write effects =
  match read_bytes t.snapshot_path with
  | Error fault -> Stopped (stop_of_snapshot_fault fault)
  | Ok bytes ->
    let observed = Digest.digest_of_bytes bytes in
    if not (same observed t.digest)
    then Stopped (Log_diverged { expected = t.digest; observed })
    else (
      let cause = Log.Direct { by; trace; write } in
      match Envelope.next ~previous:t.memory ~at cause effects with
      | Error refusal -> Not_a_snapshot refusal
      | Ok next ->
        let after, revision =
          match next with
          | Unchanged -> t.digest, t.memory.revision
          | Rewritten { snapshot; bytes } -> Digest.digest_of_bytes bytes, snapshot.revision
        in
        let line = line_after t.tail ~at ~basis:t.digest ~after ~revision ~cause ~effects in
        (match append t line with
         | Error stop -> Stopped stop
         | Ok log_end ->
           let store = { t with log_end; tail = Committed line } in
           (match next with
            | Unchanged -> Committed { store; line }
            | Rewritten { snapshot; bytes } ->
              (match write_snapshot t.snapshot_path bytes with
               | Ok () -> Committed { store = { store with memory = snapshot; digest = after }; line }
               | Error () -> Committed_without_snapshot line))))
;;

type adoption_refusal =
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Not_adopted of stop

(* Where the adopted snapshot goes in the log is read from the log as it is
   now. A last line that decodes still says where reading was. Without one
   that place is not known, and reading starts over. *)
let adopt ~memory_dir ~turns_dir ~keeper_id ~at ~by ~observed =
  let ( let* ) = Result.bind in
  let log_path = Log_store.path_for_keepers_dir ~keepers_dir:memory_dir ~keeper_id in
  let snapshot_path =
    Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:memory_dir ~keeper_id
  in
  let* memory =
    match read_bytes snapshot_path with
    | Error Snapshot_fault.Not_read -> Error (Not_adopted Store_unwritable)
    | Error (Absent | Not_a_snapshot_file) -> Error Snapshot_mismatch
    | Ok bytes ->
      if not (same (Digest.digest_of_bytes bytes) observed)
      then Error Snapshot_mismatch
      else (
        match decoded bytes with
        | Some memory -> Ok memory
        | None -> Error Snapshot_unreadable)
  in
  let start_over ~at_end =
    let turn_log_path = Turn_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id in
    let* start = Result.map_error (fun stop -> Not_adopted stop) (turn_log_start turn_log_path) in
    Ok (at_end, started ~at ~start ~memory ~digest:observed)
  in
  let* log_end, line =
    match Log_store.read_tail log_path with
    | Error (Log_store.Read_failed _ | Moved_while_reading) -> Error (Not_adopted Store_unwritable)
    | Error (Tail_undecodable { rows_end; offset = (_ : int); reason = (_ : Log_store.undecodable) })
      -> start_over ~at_end:rows_end
    | Ok Nothing_written -> start_over ~at_end:0
    | Ok (Written { rows_end; last; last_at = (_ : int) }) ->
      Ok
        ( rows_end
        , Log.Committed
            (line_after last ~at ~basis:(named last) ~after:observed ~revision:memory.revision
               ~cause:(Adopt { by; observed })
               ~effects:Librarian_effects.empty) )
  in
  match Log_store.append ~path:log_path ~at_end:log_end line with
  | Ok { new_end; at = (_ : int) } ->
    Ok { log_path; snapshot_path; log_end = new_end; tail = line; memory; digest = observed }
  | Error (Log_store.End_moved _ | Directory_unavailable _ | Write_failed _) ->
    Error (Not_adopted Store_unwritable)
;;
