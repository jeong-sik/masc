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
  | Raised of raised

and raised = { detail : string }

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
let read_snapshot_bytes path : (string, Snapshot_fault.t) result =
  match Fs_compat.load_regular_file_opt path with
  | Ok None -> Error Snapshot_fault.Absent
  | Ok (Some bytes) -> Ok bytes
  | Error (Fs_compat.Not_a_regular_file (_ : Unix.file_kind)) ->
    Error Snapshot_fault.Not_a_snapshot_file
  | Error (Fs_compat.Regular_file_unreadable (_ : string)) -> Error Snapshot_fault.Not_read
;;

let decode_snapshot bytes =
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
  match read_snapshot_bytes path with
  | Error fault -> Error fault
  | Ok bytes ->
    (match decode_snapshot bytes with
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

(* Where a commit leaves reading. *)
type reading =
  | Stays (* A direct write and an adoption move neither it nor the working state. *)
  | Moves of
      { reach : Librarian_read_result.reach
      ; working_state : Librarian_plan.working_state
      }
  | Stays_with of Librarian_plan.working_state
  (* An answer that makes room does not move it, and may replace the working
     state. *)

(* The working state a line carries: the plan's when it replaced it,
   otherwise the line before's. *)
let working_state_after ~(before : string option) : Librarian_plan.working_state -> string option =
  function
  | Kept | Alone (_ : Log.alone_working_state) -> before
  | Replaced text -> Some text
;;

(* A line carries the reading position and the working state of the line
   before it, unless it moves them. The turn log it reads is always the one
   before it names: an event that replaces the file cancels the ask. *)
let line_after (tail : Log.line) ~at ~basis ~after ~revision ~cause ~effects ~reading
  : Log.commit
  =
  let kept : Log.commit =
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
  in
  match reading with
  | Stays -> kept
  | Moves { reach; working_state } ->
    { kept with
      turn_log_offset = reach.turn_log_offset
    ; covers_through = Through { line = reach.line; within = reach.within }
    ; covered = reach.covered
    ; working_state = working_state_after ~before:kept.working_state working_state
    }
  | Stays_with working_state ->
    { kept with working_state = working_state_after ~before:kept.working_state working_state }
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

(* Steps 2 to 5 of §8.2: the file holds the snapshot the last line names,
   the line follows that one, it is appended and synced, and the snapshot is
   written when the line changes it. *)
let commit t ~at ~cause ~effects ~reading =
  match read_snapshot_bytes t.snapshot_path with
  | Error fault -> Stopped (stop_of_snapshot_fault fault)
  | Ok bytes ->
    let observed = Digest.digest_of_bytes bytes in
    if not (same observed t.digest)
    then Stopped (Log_diverged { expected = t.digest; observed })
    else (
      match Envelope.next ~previous:t.memory ~at cause effects with
      | Error refusal -> Not_a_snapshot refusal
      | Ok next ->
        let after, revision =
          match next with
          | Unchanged -> t.digest, t.memory.revision
          | Rewritten { snapshot; bytes } -> Digest.digest_of_bytes bytes, snapshot.revision
        in
        let line =
          line_after t.tail ~at ~basis:t.digest ~after ~revision ~cause ~effects ~reading
        in
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

let commit_direct t ~at ~by ~trace write effects =
  commit t ~at ~cause:(Log.Direct { by; trace; write }) ~effects ~reading:Stays
;;

let commit_read t ~at ~(question : Librarian_read_result.question) ~slot (plan : Librarian_plan.t)
  =
  (* The plan read what the question showed, and keeps a working state the
     question did not show. *)
  let shown : Log.shown =
    match plan.working_state with
    | Kept | Replaced (_ : string) -> With_memory
    | Alone state -> Item_alone state
  in
  let cause =
    Log.Read
      { question = question.id
      ; shown
      ; slot
      ; trace = question.trace
      ; missing = question.missing
      }
  in
  commit t ~at ~cause ~effects:plan.effects
    ~reading:(Moves { reach = question.reach; working_state = plan.working_state })
;;

(* §7.4 「자리 내기」 and §8.4: the line does not move reading. *)
let commit_room t ~at ~(question : Librarian_room_result.question) ~slot (plan : Librarian_plan.t) =
  commit t ~at
    ~cause:(Log.Make_room { question = question.id; slot; trace = question.trace })
    ~effects:plan.effects ~reading:(Stays_with plan.working_state)
;;

(* The working state of the tail, as a reading question shows it. *)
let tail_working_state t =
  match t.tail with
  | Started _ -> None
  | Committed commit -> commit.working_state
;;

(* [Set ""] clears the working state ({!Librarian_answer.working_state}): a
   line that holds [""] and a line that holds none both hold no working
   state, so replacing one with the other changes nothing. *)
let stated : string option -> string option = function
  | Some "" | None -> None
  | Some text -> Some text
;;

let changes t (plan : Librarian_plan.t) =
  Envelope.changes_facts plan.effects
  ||
  let before = tail_working_state t in
  not
    (Option.equal String.equal (stated before)
       (stated (working_state_after ~before plan.working_state)))
;;

let commit_skip t ~at ~hole reach =
  commit t ~at ~cause:(Log.Skip { hole }) ~effects:Librarian_effects.empty
    ~reading:(Moves { reach; working_state = Kept })
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
    match read_snapshot_bytes snapshot_path with
    | Error Snapshot_fault.Not_read -> Error (Not_adopted Store_unwritable)
    | Error (Absent | Not_a_snapshot_file) -> Error Snapshot_mismatch
    | Ok bytes ->
      if not (same (Digest.digest_of_bytes bytes) observed)
      then Error Snapshot_mismatch
      else (
        match decode_snapshot bytes with
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
               ~effects:Librarian_effects.empty ~reading:Stays) )
  in
  match Log_store.append ~path:log_path ~at_end:log_end line with
  | Ok { new_end; at = (_ : int) } ->
    Ok { log_path; snapshot_path; log_end = new_end; tail = line; memory; digest = observed }
  | Error (Log_store.End_moved _ | Directory_unavailable _ | Write_failed _) ->
    Error (Not_adopted Store_unwritable)
;;
