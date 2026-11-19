module Log = Keeper_turn_log
module Marks = Keeper_turn_log_marks
module Store = Keeper_turn_log_store

type ending =
  | Completed
  | Errored
  | Cancelled
  | Save_failed
  | Stale_save

type admitted =
  | Recorded of { opened : int }
  | Not_recorded

type event =
  | Admit of
      { turn_ref : Ids.Turn_ref.t
      ; runtime : string
      ; task : Log.task_evidence
      }
  | Finish of
      { admitted : admitted
      ; ending : ending
      }
  | Process_start

let outcome_of_ending : ending -> Log.outcome = function
  | Completed -> Completed
  | Errored -> Errored
  | Cancelled -> Cancelled
  | Save_failed -> Save_failed
  | Stale_save -> Stale_save
;;

let head_was_replaced ~(point : Log.mark) ~(now : Log.mark) =
  (not (String.equal now.trace point.trace)) || now.closed_messages < point.closed_messages
;;

let ( let* ) = Result.bind

let closed ~at ~covered ~(point : Log.mark) ~(now : Log.mark) ~(open_turn : Store.open_turn)
  ~reset_since outcome
  =
  let from = point.closed_messages in
  let through = now.closed_messages in
  (* What was closed before the turn was admitted is not the turn's. After a
     reset none of it is: the baseline counts another head.

     The baseline is clamped into the range. It lies outside only when a
     head was replaced by one that had already grown past the last mark,
     which a count cannot see. Without the clamp such a turn could never be
     closed, and neither could any turn after it. *)
  let split =
    if reset_since
    then through
    else Int.max from (Int.min open_turn.baseline.closed_messages through)
  in
  let* unattributed = Marks.slices covered ~from ~through:split in
  let* own = Marks.slices covered ~from:split ~through in
  Ok (Log.Closed { turn = open_turn.opened; at; outcome; after = now; unattributed; own })
;;

let plan ~at ~new_log_id ~(tail : Store.tail) ~(now : Log.mark) ~covered event =
  let opened ~turn_ref ~runtime ~task = Log.Opened { at; turn_ref; runtime; task; baseline = now } in
  match tail with
  | Nothing_written ->
    let started = Log.Log_started { id = new_log_id; at; mark = now } in
    (match event with
     | Admit { turn_ref; runtime; task } -> Ok [ started; opened ~turn_ref ~runtime ~task ]
     | Process_start -> Ok [ started ]
     | Finish { admitted = Recorded { opened = (_ : int) } | Not_recorded; ending = (_ : ending) }
       -> Ok [])
  | Written { point; open_turn; rows_end = (_ : int); last = (_ : Log.line) } ->
    let replaced = head_was_replaced ~point ~now in
    (* The reset goes in front of this event's own line, in the same append.
       Only the history's part of the mark moves: the other stores are read
       on from where the last line left them. From the empty mark the head
       cannot be lower again, so the reset is not written twice. *)
    let reset, point =
      if replaced
      then (
        let after = { point with trace = now.trace; closed_messages = 0 } in
        ( [ Log.Reset { at; cause = Unannounced; before = point; after; closed_before = [] } ]
        , after ))
      else [], point
    in
    let close (open_turn : Store.open_turn) outcome =
      let* line =
        closed ~at ~covered ~point ~now ~open_turn
          ~reset_since:(open_turn.reset_since || replaced)
          outcome
      in
      Ok (reset @ [ line ])
    in
    (match event, open_turn with
     | Admit { turn_ref; runtime; task }, None -> Ok (reset @ [ opened ~turn_ref ~runtime ~task ])
     | Admit { turn_ref; runtime; task }, Some open_turn ->
       let* lines = close open_turn Close_missing in
       Ok (lines @ [ opened ~turn_ref ~runtime ~task ])
     | Finish { admitted = Recorded { opened }; ending }, Some open_turn ->
       (* Another writer closed this turn already, and the open one is not
          this turn's to close. *)
       if Int.equal open_turn.opened opened
       then close open_turn (outcome_of_ending ending)
       else Ok []
     | Finish { admitted = Not_recorded; ending = (_ : ending) }, Some (_ : Store.open_turn)
     | Finish { admitted = Recorded _ | Not_recorded; ending = (_ : ending) }, None -> Ok []
     | Process_start, Some open_turn -> close open_turn Process_exited
     | Process_start, None -> Ok [])
;;
