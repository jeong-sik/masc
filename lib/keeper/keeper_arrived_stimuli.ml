type row =
  { arrival : int64
  ; urgency : Keeper_event_queue.urgency
  ; arrived_at : float
  ; preview : string
  }

let max_rows_per_round = 8

type round =
  { listed : row list
  ; later : int
  }

let row_of_selection (selection : Keeper_event_queue_state.pending_selection) =
  { arrival = selection.arrival
  ; urgency = selection.source.urgency
  ; arrived_at = selection.source.arrived_at
  ; preview = Keeper_reaction_ledger.stimulus_payload_preview selection.source.payload
  }
;;

let compare_arrival (left : row) (right : row) =
  match Float.compare left.arrived_at right.arrived_at with
  | 0 -> Int64.compare left.arrival right.arrival
  | order -> order
;;

let rec take n = function
  | [] -> [], []
  | rows when n <= 0 -> [], rows
  | row :: rest ->
    let taken, left = take (n - 1) rest in
    row :: taken, left
;;

let next_round ~run_started_at ~shown selections =
  let unseen =
    selections
    |> List.filter (fun (selection : Keeper_event_queue_state.pending_selection) ->
      selection.source.arrived_at > run_started_at
      && not (List.exists (Int64.equal selection.arrival) shown))
    |> List.map row_of_selection
    |> List.sort compare_arrival
  in
  let listed, later = take max_rows_per_round unseen in
  { listed; later = List.length later }
;;

let age_text seconds =
  let seconds = Int.max 0 (int_of_float seconds) in
  if seconds < 60
  then Printf.sprintf "%ds" seconds
  else if seconds < 3600
  then Printf.sprintf "%dm" (seconds / 60)
  else Printf.sprintf "%dh%02dm" (seconds / 3600) (seconds mod 3600 / 60)
;;

let urgency_text = function
  | Keeper_event_queue.Immediate -> "immediate"
  | Keeper_event_queue.Normal -> "normal"
  | Keeper_event_queue.Low -> "low"
;;

let render ~now { listed; later } =
  match listed with
  | [] -> None
  | _ :: _ ->
    let arrived = List.length listed + later in
    let lines =
      List.map
        (fun (row : row) ->
           Printf.sprintf
             "- %s, %s ago: %s"
             (urgency_text row.urgency)
             (age_text (now -. row.arrived_at))
             row.preview)
        listed
    in
    let more =
      if later = 0 then [] else [ Printf.sprintf "- %d more arrived; the next round lists them" later ]
    in
    Some
      (String.concat
         "\n"
         ([ "--- Arrived While This Turn Ran ---"
          ; Printf.sprintf
              "%d row(s) reached your queue after this turn began. They stay queued and \
               start their own turn after this one ends."
              arrived
          ]
          @ lines
          @ more))
;;

type tracker =
  { run_started_at : float
  ; mutable listed_for_good : int64 list
  ; mutable awaiting_answer : int64 list
  }

let create_tracker ~run_started_at = { run_started_at; listed_for_good = []; awaiting_answer = [] }

let next tracker selections =
  let round =
    next_round ~run_started_at:tracker.run_started_at ~shown:tracker.listed_for_good selections
  in
  tracker.awaiting_answer <- List.map (fun (row : row) -> row.arrival) round.listed;
  round
;;

let confirm tracker =
  tracker.listed_for_good <- tracker.awaiting_answer @ tracker.listed_for_good;
  tracker.awaiting_answer <- []
;;

let block tracker ~now ~read ~on_unavailable =
  match read () with
  | Error detail ->
    on_unavailable detail;
    None
  | Ok selections -> render ~now (next tracker selections)
;;

type claim =
  { round : round
  ; text : string
  ; confirm : unit -> unit
  }

let claim tracker ~now ~read ~on_unavailable =
  match read () with
  | Error detail ->
    on_unavailable detail;
    None
  | Ok selections ->
    let round =
      next_round
        ~run_started_at:tracker.run_started_at
        ~shown:tracker.listed_for_good
        selections
    in
    Option.map
      (fun text ->
         { round
         ; text
         ; confirm =
             (fun () ->
               tracker.listed_for_good
               <- List.map (fun (row : row) -> row.arrival) round.listed
                  @ tracker.listed_for_good)
         })
      (render ~now round)
;;
