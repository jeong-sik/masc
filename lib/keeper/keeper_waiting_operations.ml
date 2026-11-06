type waiting =
  | Not_waiting
  | Waiting of { queued : int }

let waiting_of_projection ~store_unavailable ~queued_count ~has_claimable_queued =
  if store_unavailable
  then Error "the chat operation store is unavailable; its counts are from the last good read"
  else if queued_count < 0
  then Error (Printf.sprintf "queued chat operation count %d is negative" queued_count)
  else if queued_count = 0
  then
    if has_claimable_queued
    then Error "a claimable chat operation is reported with a zero queued count"
    else Ok Not_waiting
  else if has_claimable_queued
  then Ok (Waiting { queued = queued_count })
  else Ok Not_waiting
;;

let render = function
  | Not_waiting -> None
  | Waiting { queued } ->
    Some
      (String.concat
         "\n"
         [ "--- Chat Requests Waiting ---"
         ; Printf.sprintf
             "%d chat request(s) are queued for you; at least one is ready and starts after \
              this turn ends."
             queued
         ])
;;

type tracker =
  { mutable told : int
  ; mutable awaiting_answer : int option
  }

let create_tracker () = { told = 0; awaiting_answer = None }

let queued_of = function
  | Not_waiting -> 0
  | Waiting { queued } -> queued
;;

let next tracker waiting =
  let queued = queued_of waiting in
  if queued > tracker.told
  then (
    tracker.awaiting_answer <- Some queued;
    Some waiting)
  else (
    tracker.awaiting_answer <- None;
    tracker.told <- queued;
    None)
;;

let confirm tracker =
  Option.iter (fun queued -> tracker.told <- queued) tracker.awaiting_answer;
  tracker.awaiting_answer <- None
;;

let block tracker ~read ~on_unavailable =
  match read () with
  | Error detail ->
    on_unavailable detail;
    None
  | Ok waiting -> Option.bind (next tracker waiting) render
;;
