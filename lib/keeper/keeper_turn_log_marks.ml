module Objects = Agent_core.Checkpoint_objects

let messages_of turns =
  List.fold_left (fun total (turn : Objects.turn) -> total + turn.messages) 0 turns
;;

(* [Objects.message_count] is the one definition of how many messages a head
   holds. The open ones are the only part a mark leaves out. *)
let closed_messages (history : Objects.history) =
  Objects.message_count history - List.length history.open_messages
;;

type covered =
  { first : int
  ; turns : Objects.turn list
  ; before : Objects.digest option
  }

let of_head (history : Objects.history) =
  match history.segment with
  | Some segment ->
    { first = segment.segment_messages; turns = history.turns; before = Some segment.segment }
  | None -> { first = 0; turns = history.turns; before = None }
;;

let first covered = covered.first
let segment_before covered = covered.before

type segment_error =
  | Nothing_before
  | Does_not_fit of
      { first : int
      ; segment_messages : int
      ; has_previous : bool
      }

let with_segment_before (segment : Objects.segment) covered =
  match covered.before with
  | None -> Error Nothing_before
  | Some (_ : Objects.digest) ->
    let segment_messages = messages_of segment.segment_turns in
    let first = covered.first - segment_messages in
    let has_previous = Option.is_some segment.previous in
    (* A segment holds at least one message, so the history starts at this
       segment exactly when no segment comes before it. *)
    if first < 0 || Bool.equal (first = 0) has_previous
    then Error (Does_not_fit { first = covered.first; segment_messages; has_previous })
    else
      Ok { first; turns = segment.segment_turns @ covered.turns; before = segment.previous }
;;

type range_error =
  | Starts_before_covered of
      { from : int
      ; first : int
      }
  | Ends_after_covered of
      { through : int
      ; last : int
      }
  | Backwards of
      { from : int
      ; through : int
      }

let slices covered ~from ~through =
  let last = covered.first + messages_of covered.turns in
  if from > through
  then Error (Backwards { from; through })
  else if from < covered.first
  then Error (Starts_before_covered { from; first = covered.first })
  else if through > last
  then Error (Ends_after_covered { through; last })
  else (
    let slices, (_ : int) =
      List.fold_left
        (fun (slices, start) (turn : Objects.turn) ->
           let stop = start + turn.messages in
           let low = Int.max start from in
           let high = Int.min stop through in
           let slices =
             if high > low
             then
               ({ bundle = turn.bundle; skip = low - start; take = high - low }
                : Keeper_turn_log.slice)
               :: slices
             else slices
           in
           slices, stop)
        ([], covered.first)
        covered.turns
    in
    Ok (List.rev slices))
;;
