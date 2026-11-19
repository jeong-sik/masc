module Log = Keeper_turn_log
module Store = Keeper_turn_log_store
module Writer = Keeper_turn_log_writer
module Head = Keeper_turn_log_head
module Ends = Keeper_turn_log_ends

type place =
  { keepers_dir : string
  ; base_path : string
  ; keeper_name : string
  ; session_dir : string
  ; session_id : string
  }

type not_recorded =
  | Tail_unread of Store.read_error
  | Head_unread of Keeper_checkpoint_store_decode.checkpoint_load_error
  | Ends_unread of Ends.error
  | Run_unnamed of Head.covering_error
  | Not_appended of Store.append_error

let range_error_to_string : Keeper_turn_log_marks.range_error -> string = function
  | Starts_before_covered { from; first } ->
    Printf.sprintf "the run starts at message %d, before the first covered one %d" from first
  | Ends_after_covered { through; last } ->
    Printf.sprintf "the run ends at message %d, after the last closed one %d" through last
  | Backwards { from; through } ->
    Printf.sprintf "the run goes from message %d back to %d" from through
;;

let covering_error_to_string : Head.covering_error -> string = function
  | Range error -> range_error_to_string error
  | Segment Nothing_before -> "the run starts before message 0"
  | Segment (Not_read unread) -> Head.segment_unread_to_string unread
  | Segment (Does_not_fit { first; segment_messages; has_previous }) ->
    Printf.sprintf "the segment before message %d holds %d messages and names %s before it"
      first segment_messages
      (if has_previous then "one" else "none")
;;

let read_error_to_string : Store.read_error -> string = function
  | Read_failed { path; detail } -> Printf.sprintf "the turn log %s was not read: %s" path detail
  | Row_undecodable { offset; reason = Not_json } ->
    Printf.sprintf "the turn log line at byte %d is not JSON" offset
  | Row_undecodable { offset; reason = Malformed error } ->
    Printf.sprintf "the turn log line at byte %d: %s" offset
      (Keeper_memory_os_types.wire_error_to_string error)
  | Log_start_missing -> "the turn log has lines and none starts it"
  | Moved_while_reading -> "the turn log changed while its tail was read"
;;

let append_error_to_string : Store.append_error -> string = function
  | End_moved { expected; actual } ->
    Printf.sprintf "the turn log was read to end at byte %d and is %d bytes long" expected actual
  | Directory_unavailable { path; detail } | Write_failed { path; detail } ->
    Printf.sprintf "the turn log %s was not written: %s" path detail
;;

let not_recorded_to_string = function
  | Tail_unread error -> read_error_to_string error
  | Head_unread error -> Keeper_checkpoint_store_session.checkpoint_load_error_to_string error
  | Ends_unread error -> Ends.error_to_string error
  | Run_unnamed error -> covering_error_to_string error
  | Not_appended error -> append_error_to_string error
;;

type recorded =
  | Nothing_to_append
  | Appended of
      { lines : Log.line list
      ; at : Store.appended
      }

let ( let* ) = Result.bind

let now place =
  let* head =
    Result.map_error
      (fun error -> Head_unread error)
      (Head.read ~session_dir:place.session_dir ~session_id:place.session_id)
  in
  let* ends =
    Result.map_error
      (fun error -> Ends_unread error)
      (Ends.read ~session_dir:place.session_dir ~base_path:place.base_path
         ~keeper_name:place.keeper_name)
  in
  let mark : Log.mark =
    { trace = place.session_id
    ; closed_messages = head.closed_messages
    ; session = place.session_id
    ; history_bytes = ends.history_bytes
    ; internal_bytes = ends.internal_bytes
    ; chat_bytes = ends.chat_bytes
    ; external_rows = ends.external_rows
    }
  in
  Ok (mark, head.covered)
;;

let record ~at ~new_log_id place event =
  let path =
    Store.path_for_keepers_dir ~keepers_dir:place.keepers_dir ~keeper_id:place.keeper_name
  in
  (* [moved_at] is the end the attempt before read and could not append at. *)
  let rec attempt ~moved_at =
    let* tail = Result.map_error (fun error -> Tail_unread error) (Store.read_tail path) in
    let at_end =
      match tail with
      | Store.Nothing_written -> 0
      | Written { rows_end; _ } -> rows_end
    in
    let* mark, covered = now place in
    let* lines =
      Result.map_error
        (fun error -> Run_unnamed error)
        (Head.with_segments_as_needed ~session_dir:place.session_dir covered (fun covered ->
           Writer.plan ~at ~new_log_id ~tail ~now:mark ~covered event))
    in
    match lines with
    | [] -> Ok Nothing_to_append
    | first :: rest ->
      (match Store.append ~path ~at_end (first, rest) with
       | Ok appended -> Ok (Appended { lines; at = appended })
       | Error (Store.End_moved _ as error) ->
         (match moved_at with
          | Some before when Int.equal before at_end -> Error (Not_appended error)
          | Some (_ : int) | None -> attempt ~moved_at:(Some at_end))
       | Error ((Store.Directory_unavailable _ | Write_failed _) as error) ->
         Error (Not_appended error))
  in
  attempt ~moved_at:None
;;

let admitted = function
  | Ok (Appended { at; _ }) -> Writer.Recorded { opened = at.last_at }
  | Ok Nothing_to_append | Error (_ : not_recorded) -> Writer.Not_recorded
;;
