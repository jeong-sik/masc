module Log = Keeper_turn_log
module Codec = Keeper_turn_log_codec

let file_name = "turns.jsonl"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) file_name
;;

type open_turn =
  { opened : int
  ; baseline : Log.mark
  }

type tail =
  | Nothing_written
  | Written of
      { rows_end : int
      ; point : Log.mark
      ; open_turn : open_turn option
      ; last : Log.line
      }

type undecodable =
  | Not_json
  | Malformed of Keeper_memory_os_types.wire_error

type read_error =
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Row_undecodable of
      { offset : int
      ; reason : undecodable
      }
  | Log_start_missing

let decode row =
  match Yojson.Safe.from_string row with
  | exception Yojson.Json_error (_ : string) -> Error Not_json
  | json -> Result.map_error (fun error -> Malformed error) (Codec.of_json json)
;;

type turn_seen =
  | Not_yet
  | No_open_turn
  | Open_turn of open_turn

(* What a walk back from the end has found. The window reader hands over one
   row at a time, newest first, through a callback that can only answer "stop
   here", so the findings are kept beside it. *)
type walk =
  { mutable row_end : int (* Where the row before the one last visited ends. *)
  ; mutable last : Log.line option
  ; mutable point : Log.mark option
  ; mutable turn : turn_seen
  ; mutable failure : read_error option
  }

let visit walk row =
  let offset = walk.row_end - String.length row - 1 in
  walk.row_end <- offset;
  match decode row with
  | Error reason ->
    walk.failure <- Some (Row_undecodable { offset; reason });
    true
  | Ok line ->
    (match walk.last with
     | None -> walk.last <- Some line
     | Some (_ : Log.line) -> ());
    (match walk.point, Log.boundary line with
     | None, (Starts_at mark | Ends_unit { next = mark; through = (_ : Log.mark) }) ->
       walk.point <- Some mark
     | None, Moves_nothing | Some (_ : Log.mark), (Starts_at _ | Ends_unit _ | Moves_nothing) -> ());
    (match walk.turn, line with
     | Not_yet, Opened { baseline; _ } -> walk.turn <- Open_turn { opened = offset; baseline }
     | Not_yet, (Closed _ | Log_started _) -> walk.turn <- No_open_turn
     | Not_yet, Reset _
     | (No_open_turn | Open_turn _), (Log_started _ | Opened _ | Closed _ | Reset _) -> ());
    (match walk.point, walk.turn with
     | Some (_ : Log.mark), (No_open_turn | Open_turn _) -> true
     | None, (Not_yet | No_open_turn | Open_turn _) | Some _, Not_yet -> false)
;;

let window path ~from ~previous_row_wanted =
  match
    Fs_compat.read_private_jsonl_window_locked_result path ~from ~max_rows:1 ~previous_row_wanted
  with
  | Fs_compat.Private_file_succeeded window
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = window; _ } -> Ok window
  | Fs_compat.Private_file_failed error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; _ } ->
    Error (Read_failed { path; detail = Fs_compat.Private_jsonl_rows.error_to_string error })
;;

let read_tail path =
  let ( let* ) = Result.bind in
  let* first = window path ~from:0 ~previous_row_wanted:(fun (_ : string) -> false) in
  match first with
  | Fs_compat.Private_jsonl_window.Window_missing -> Ok Nothing_written
  | Window_present { rows_end = 0; _ } -> Ok Nothing_written
  | Window_present { rows_end; _ } ->
    let walk = { row_end = rows_end; last = None; point = None; turn = Not_yet; failure = None } in
    let* (_ : Fs_compat.Private_jsonl_window.t) =
      window path ~from:rows_end ~previous_row_wanted:(visit walk)
    in
    (match walk.failure, walk.last, walk.point, walk.turn with
     | Some failure, _, _, _ -> Error failure
     | None, Some last, Some point, No_open_turn ->
       Ok (Written { rows_end; point; open_turn = None; last })
     | None, Some last, Some point, Open_turn open_turn ->
       Ok (Written { rows_end; point; open_turn = Some open_turn; last })
     | None, None, _, _ | None, Some _, None, _ | None, Some _, Some _, Not_yet ->
       Error Log_start_missing)
;;

type append_error =
  | End_moved of
      { expected : int
      ; actual : int
      }
  | Directory_unavailable of
      { path : string
      ; detail : string
      }
  | Write_failed of
      { path : string
      ; detail : string
      }

let row line = Yojson.Safe.to_string (Codec.to_json line) ^ "\n"

let append ~path ~at_end (first, rest) =
  let suffix = String.concat "" (List.map row (first :: rest)) in
  let dir = Filename.dirname path in
  (* The offset-checked append does not create its directory. *)
  match Fs_compat.mkdir_p_memoized dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Directory_unavailable { path = dir; detail = Printexc.to_string exn })
  | () ->
    (match
       Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result path
         ~expected_end_offset:at_end suffix
     with
     (* The lines are on disk. A cleanup failure is about the descriptor, and
        calling it a write failure would invite a second append. *)
     | Fs_compat.Private_file_succeeded new_end
     | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = new_end; _ } -> Ok new_end
     | Fs_compat.Private_file_failed (Fs_compat.End_offset_mismatch { expected; actual })
     | Fs_compat.Private_file_failed_with_cleanup_failure
         { error = Fs_compat.End_offset_mismatch { expected; actual }; _ } ->
       Error (End_moved { expected; actual })
     | Fs_compat.Private_file_failed
         (( Fs_compat.Incomplete_jsonl_tail
          | Fs_compat.Incomplete_jsonl_tail_truncate_failed _
          | Fs_compat.Existing_jsonl_refused _
          | Fs_compat.Invalid_jsonl_suffix
          | Fs_compat.Negative_expected_end_offset _
          | Fs_compat.Durable_jsonl_append_failed _ ) as error)
     | Fs_compat.Private_file_failed_with_cleanup_failure
         { error =
             ( Fs_compat.Incomplete_jsonl_tail
             | Fs_compat.Incomplete_jsonl_tail_truncate_failed _
             | Fs_compat.Existing_jsonl_refused _
             | Fs_compat.Invalid_jsonl_suffix
             | Fs_compat.Negative_expected_end_offset _
             | Fs_compat.Durable_jsonl_append_failed _ ) as error
         ; _
         } ->
       Error (Write_failed { path; detail = Fs_compat.private_jsonl_append_error_to_string error }))
;;
