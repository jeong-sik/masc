module Closing = Keeper_turn_log_closing
module Recorder = Keeper_turn_log_recorder
module Writer = Keeper_turn_log_writer

type 'refused refusal =
  | Path_refused of 'refused
  | Open_not_closed of Closing.not_closed
  | Line_not_written of Recorder.not_recorded
  | Line_not_planned

let run ~at ~new_log_id place ~cause ~prepare ~after ~change =
  let checked () = Result.map_error (fun refused -> Path_refused refused) (prepare ()) in
  let ( let* ) = Result.bind in
  let* plan = checked () in
  let* plan =
    match Closing.close_open place with
    | Closing.Nothing_open -> Ok plan
    (* The save moved the head the plan was made against. *)
    | Closing.Closed_open { messages = (_ : int) } -> checked ()
    | Closing.Not_closed error -> Error (Open_not_closed error)
  in
  match Recorder.record ~at ~new_log_id place (Writer.Reset { cause; after = after plan }) with
  | Error error -> Error (Line_not_written error)
  | Ok Recorder.Nothing_to_append -> Error Line_not_planned
  | Ok (Recorder.Appended { lines = (_ : Keeper_turn_log.line list); at = (_ : Keeper_turn_log_store.appended) })
    -> Ok (change plan)
;;

let refusal_to_string refused_to_string = function
  | Path_refused refused -> refused_to_string refused
  | Open_not_closed error ->
    "the head's open messages were not closed: " ^ Closing.not_closed_to_string error
  | Line_not_written error ->
    "the turn log line was not written: " ^ Recorder.not_recorded_to_string error
  | Line_not_planned -> "the turn log planned no reset line"
;;
