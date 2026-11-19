module Objects = Agent_core.Checkpoint_objects
module Marks = Keeper_turn_log_marks
module Decode = Keeper_checkpoint_store_decode

type t =
  { closed_messages : int
  ; open_messages : int
  ; covered : Marks.covered
  }

let of_history (history : Objects.history) =
  { closed_messages = Marks.closed_messages history
  ; open_messages = List.length history.open_messages
  ; covered = Marks.of_head history
  }
;;

let empty = of_history { segment = None; turns = []; open_messages = [] }

let read ~session_dir ~session_id =
  let canonical_path =
    Keeper_checkpoint_store_history_files.agent_core_checkpoint_path ~session_dir ~session_id
  in
  match Keeper_checkpoint_store_canonical.known_canonical ~canonical_path with
  | Ok (Some known) -> Ok (of_history known.known_head.history)
  (* The two a turn starts fresh from. *)
  | Ok None | Error Decode.Not_found | Error (Decode.Superseded_version _) -> Ok empty
  | Error
      (( Decode.Store_error _
       | Decode.Parse_error _
       | Decode.Newer_version _
       | Decode.Io_error _
       | Decode.Read_failed _
       | Decode.Agent_core_error _
       | Decode.Objects_invalid _ ) as error) -> Error error
;;

type segment_unread =
  | Segment_missing
  | Segment_unreadable of string
  | Segment_invalid of Objects.load_error

let segment_unread_to_string = function
  | Segment_missing -> "the segment object is not in the session"
  | Segment_unreadable detail -> "the segment object could not be read: " ^ detail
  | Segment_invalid error -> Objects.load_error_to_string error
;;

let load_segment ~session_dir digest =
  match Keeper_checkpoint_object_store.read ~session_dir digest with
  | Error detail -> Error (Segment_unreadable detail)
  | Ok None -> Error Segment_missing
  | Ok (Some bytes) ->
    Result.map_error
      (fun error -> Segment_invalid error)
      (Objects.segment_of_string ~digest bytes)
;;

type covering_error =
  | Ends_after_covered of
      { through : int
      ; last : int
      }
  | Backwards of
      { from : int
      ; through : int
      }
  | Segment of segment_unread Marks.segment_error

(* Each round puts one more segment in front, and the segments behind a head
   are a chain of content names: it ends. *)
let rec with_segments_as_needed ~session_dir covered ask =
  match ask covered with
  | Ok answer -> Ok answer
  | Error (Marks.Starts_before_covered _) ->
    (match Marks.with_segment_before ~load:(load_segment ~session_dir) covered with
     | Ok covered -> with_segments_as_needed ~session_dir covered ask
     | Error error -> Error (Segment error))
  | Error (Marks.Ends_after_covered { through; last }) ->
    Error (Ends_after_covered { through; last })
  | Error (Marks.Backwards { from; through }) -> Error (Backwards { from; through })
;;
