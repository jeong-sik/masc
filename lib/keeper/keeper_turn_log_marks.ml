module Objects = Agent_core.Checkpoint_objects

let messages_of turns =
  List.fold_left (fun total (turn : Objects.turn) -> total + turn.messages) 0 turns
;;

let before_head (history : Objects.history) =
  match history.segment with
  | Some segment -> segment.segment_messages
  | None -> 0
;;

let closed_messages (history : Objects.history) =
  before_head history + messages_of history.turns
;;

type covered =
  { first : int
  ; turns : Objects.turn list
  }

let of_head (history : Objects.history) =
  { first = before_head history; turns = history.turns }
;;

let with_segment_before (segment : Objects.segment) covered =
  { first = covered.first - messages_of segment.segment_turns
  ; turns = segment.segment_turns @ covered.turns
  }
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
