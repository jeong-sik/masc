module Closing = Keeper_turn_log_closing
module Recorder = Keeper_turn_log_recorder
module Writer = Keeper_turn_log_writer

type line =
  | No_line
  | Announce of
      { cause : Keeper_turn_log.announced
      ; after : Keeper_turn_log.mark -> Keeper_turn_log.mark
      }
  | Drop of { after : Keeper_turn_log.mark -> Keeper_turn_log.mark }

type 'refused refusal =
  | Path_refused of 'refused
  | Open_not_closed of Closing.not_closed
  | Line_not_written of Recorder.not_recorded
  | Line_not_planned

let run ~at ~new_log_id place ~prepare ~line ~change =
  let checked () = Result.map_error (fun refused -> Path_refused refused) (prepare ()) in
  let written recorded plan =
    match recorded with
    | Error error -> Error (Line_not_written error)
    | Ok Recorder.Nothing_to_append -> Error Line_not_planned
    | Ok (Recorder.Appended { lines = (_ : Keeper_turn_log.line list); at = (_ : Keeper_turn_log_store.appended) })
      -> Ok (change plan)
  in
  (* [closed] once the closing save has run: the checks after it are the
     last, and their plan is followed whatever line it asks for. *)
  let rec follow ~closed plan =
    match line plan with
    | No_line -> Ok (change plan)
    | Drop { after } -> written (Recorder.record_drop ~at ~new_log_id place ~after) plan
    | Announce { cause; after } ->
      let announce () =
        written (Recorder.record ~at ~new_log_id place (Writer.Reset { cause; after })) plan
      in
      if closed
      then announce ()
      else (
        match Closing.close_open place with
        | Closing.Nothing_open -> announce ()
        (* The save moved the head the plan was made against. *)
        | Closing.Closed_open { messages = (_ : int) } ->
          Result.bind (checked ()) (follow ~closed:true)
        | Closing.Not_closed error -> Error (Open_not_closed error))
  in
  Result.bind (checked ()) (follow ~closed:false)
;;

let refusal_to_string refused_to_string = function
  | Path_refused refused -> refused_to_string refused
  | Open_not_closed error ->
    "the head's open messages were not closed: " ^ Closing.not_closed_to_string error
  | Line_not_written error ->
    "the turn log line was not written: " ^ Recorder.not_recorded_to_string error
  | Line_not_planned -> "the turn log planned no reset line"
;;
