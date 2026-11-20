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

let covering_error_to_string : Head.covering_error -> string = function
  | Ends_after_covered { through; last } ->
    Printf.sprintf "the run ends at message %d, after the last closed one %d" through last
  | Backwards { from; through } ->
    Printf.sprintf "the run goes from message %d back to %d" from through
  | Segment Nothing_before -> "the run starts before message 0"
  | Segment (Not_read unread) -> Head.segment_unread_to_string unread
  | Segment (Does_not_fit { first; segment_messages; has_previous }) ->
    Printf.sprintf "the segment before message %d holds %d messages and names %s before it"
      first segment_messages
      (if has_previous then "one" else "none")
;;

let append_error_to_string : Store.append_error -> string = function
  | End_moved { expected; actual } ->
    Printf.sprintf "the turn log was read to end at byte %d and is %d bytes long" expected actual
  | Directory_unavailable { path; detail } | Write_failed { path; detail } ->
    Printf.sprintf "the turn log %s was not written: %s" path detail
;;

let not_recorded_to_string = function
  | Tail_unread error -> Store.read_error_to_string error
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

let mark_at place ~closed_messages =
  let* ends =
    Result.map_error
      (fun error -> Ends_unread error)
      (Ends.read ~session_dir:place.session_dir ~base_path:place.base_path
         ~keeper_name:place.keeper_name)
  in
  Ok
    ({ trace = place.session_id
     ; closed_messages
     ; session = place.session_id
     ; history_bytes = ends.history_bytes
     ; internal_bytes = ends.internal_bytes
     ; chat_bytes = ends.chat_bytes
     ; external_rows = ends.external_rows
     }
     : Log.mark)
;;

let now place =
  let* head =
    Result.map_error
      (fun error -> Head_unread error)
      (Head.read ~session_dir:place.session_dir ~session_id:place.session_id)
  in
  let* mark = mark_at place ~closed_messages:head.closed_messages in
  Ok (mark, head.covered)
;;

(* §9.5: whoever appends a [Closed] or a [Reset] line tells the Keeper's
   Memory writer, in the same step. The hint carries nothing: the writer
   reads the turn log, and a pulse finds a turn whose hint did not come. *)
let tell_writer place lines =
  let ends_a_unit line =
    match Log.boundary line with
    | Ends_unit { through = (_ : Log.mark); next = (_ : Log.mark) } -> true
    | Starts_at (_ : Log.mark) | Moves_nothing -> false
  in
  if List.exists ends_a_unit lines
  then
    Option.iter
      (fun writers -> Librarian_writers.turn_closed writers place.keeper_name)
      (Keeper_memory_writers.find ~base_path:place.base_path)
;;

(* Reads the tail, plans against it, and appends at the end it read.
   [moved_at] is the end the attempt before read and could not append at. *)
let append_planned place plan =
  let path =
    Store.path_for_keepers_dir ~keepers_dir:place.keepers_dir ~keeper_id:place.keeper_name
  in
  let rec attempt ~moved_at =
    let* tail = Result.map_error (fun error -> Tail_unread error) (Store.read_tail path) in
    let at_end =
      match tail with
      | Store.Nothing_written -> 0
      | Written { rows_end; _ } -> rows_end
    in
    let* lines = plan tail in
    match lines with
    | [] -> Ok Nothing_to_append
    | first :: rest ->
      (match Store.append ~path ~at_end (first, rest) with
       | Ok appended ->
         tell_writer place lines;
         Ok (Appended { lines; at = appended })
       | Error (Store.End_moved _ as error) ->
         (match moved_at with
          | Some before when Int.equal before at_end -> Error (Not_appended error)
          | Some (_ : int) | None -> attempt ~moved_at:(Some at_end))
       | Error ((Store.Directory_unavailable _ | Write_failed _) as error) ->
         Error (Not_appended error))
  in
  attempt ~moved_at:None
;;

let record ~at ~new_log_id place event =
  append_planned place (fun tail ->
    let* mark, covered = now place in
    Result.map_error
      (fun error -> Run_unnamed error)
      (Head.with_segments_as_needed ~session_dir:place.session_dir covered (fun covered ->
         Writer.plan ~at ~new_log_id ~tail ~now:mark ~covered event)))
;;

let record_drop ~at ~new_log_id place ~after =
  append_planned place (fun tail ->
    let* now = mark_at place ~closed_messages:0 in
    Ok [ Writer.drop ~at ~new_log_id ~tail ~now ~after ])
;;

let record_start ~at ~new_log_id place =
  append_planned place (fun tail ->
    Writer.start ~at ~new_log_id ~tail ~now:(fun () ->
      let* mark, (_ : Keeper_turn_log_marks.covered) = now place in
      Ok mark))
;;

let admitted = function
  | Ok (Appended { at; _ }) -> Writer.Recorded { opened = at.last_at }
  | Ok Nothing_to_append | Error (_ : not_recorded) -> Writer.Not_recorded
;;
