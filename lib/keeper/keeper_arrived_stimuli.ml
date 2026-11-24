type inbound_queue_mode =
  | Steer
  | FollowUp
  | Coalesce

let inbound_queue_mode_to_string = function
  | Steer -> "steer"
  | FollowUp -> "follow_up"
  | Coalesce -> "coalesce"
;;

let inbound_mode_rank = function
  | Steer -> 0
  | FollowUp -> 1
  | Coalesce -> 2
;;

let inbound_mode_of_stimulus (stimulus : Keeper_event_queue.stimulus)
  : inbound_queue_mode
  =
  match Keeper_stimulus_wake_policy.effective_urgency stimulus, stimulus.payload with
  | ( Keeper_event_queue.Immediate
    , ( Keeper_event_queue.Workspace_message _
      | Keeper_event_queue.Connector_attention _
      | Keeper_event_queue.Hitl_resolved _
      | Keeper_event_queue.Ask_answered _
      | Keeper_event_queue.Board_signal _
      | Keeper_event_queue.Task_cancelled _
      | Keeper_event_queue.Completion_authority_rejected _ ) ) -> Steer
  | ( ( Keeper_event_queue.Immediate
      | Keeper_event_queue.Normal
      | Keeper_event_queue.Low )
    , ( Keeper_event_queue.Tool_result_ready _
      | Keeper_event_queue.Delegate_completed _
      | Keeper_event_queue.Fusion_completed _
      | Keeper_event_queue.Composition_completed _
      | Keeper_event_queue.Owned_job_completed _
      | Keeper_event_queue.Schedule_due _
      | Keeper_event_queue.Bootstrap ) ) -> FollowUp
  | ( Keeper_event_queue.Immediate
    , ( Keeper_event_queue.Board_routing_pending _
      | Keeper_event_queue.Board_attention _
      | Keeper_event_queue.Task_outcome _ ) ) -> FollowUp
  | ( (Keeper_event_queue.Normal | Keeper_event_queue.Low)
    , ( Keeper_event_queue.Workspace_message _
      | Keeper_event_queue.Connector_attention _
      | Keeper_event_queue.Hitl_resolved _
      | Keeper_event_queue.Ask_answered _
      | Keeper_event_queue.Board_signal _
      | Keeper_event_queue.Board_routing_pending _
      | Keeper_event_queue.Board_attention _
      | Keeper_event_queue.Completion_authority_rejected _
      | Keeper_event_queue.Task_cancelled _
      | Keeper_event_queue.Task_outcome _ ) ) -> Coalesce
;;

type row =
  { arrival : int64
  ; urgency : Keeper_event_queue.urgency
  ; mode : inbound_queue_mode
  ; arrived_at : float
  ; preview : string
  ; receipt_id : string option
  }

let max_rows_per_round = 8

type round =
  { listed : row list
  ; later : int
  }

let receipt_id_of_payload : Keeper_event_queue.stimulus_payload -> string option = function
  | Keeper_event_queue.Tool_result_ready receipt_id -> Some receipt_id
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_routing_pending _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Ask_answered _
  | Keeper_event_queue.Completion_authority_rejected _
  | Keeper_event_queue.Task_cancelled _
  | Keeper_event_queue.Workspace_message _
  | Keeper_event_queue.Delegate_completed _
  | Keeper_event_queue.Composition_completed _
  | Keeper_event_queue.Owned_job_completed _
  | Keeper_event_queue.Task_outcome _ -> None
;;

let row_of_selection (selection : Keeper_event_queue_state.pending_selection) =
  { arrival = selection.arrival
  ; urgency = selection.source.urgency
  ; mode = inbound_mode_of_stimulus selection.source
  ; arrived_at = selection.source.arrived_at
  ; preview = Keeper_reaction_ledger.stimulus_payload_preview selection.source.payload
  ; receipt_id = receipt_id_of_payload selection.source.payload
  }
;;

let compare_arrival (left : row) (right : row) =
  match Int.compare (inbound_mode_rank left.mode) (inbound_mode_rank right.mode) with
  | 0 ->
    (match Float.compare left.arrived_at right.arrived_at with
     | 0 -> Int64.compare left.arrival right.arrival
     | order -> order)
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

let urgency_text = function
  | Keeper_event_queue.Immediate -> "immediate"
  | Keeper_event_queue.Normal -> "normal"
  | Keeper_event_queue.Low -> "low"
;;

(* The other completion rows name what finished and how it ended
   (keeper_delegate_completed, keeper_composition_completed, fusion_completed).
   A retained result's row holds only the SHA-256 of its receipt, so the line
   asks [receipt] for the receipt's own coordinates. *)
let max_receipt_field_bytes = 96

let receipt_detail (summary : Keeper_client_tool_outbox.Summary.t) =
  let field name text =
    name
    ^ "="
    ^ Yojson.Safe.to_string (`String (String_util.utf8_prefix ~max_bytes:max_receipt_field_bytes text))
  in
  String.concat
    " "
    ([ field "call_id" summary.call_id; field "tool" summary.tool_name ]
     @ Option.fold ~none:[] ~some:(fun outcome -> [ field "outcome" outcome ]) summary.outcome)
;;

let line_text ~receipt (row : row) =
  match Option.bind row.receipt_id receipt with
  | None -> row.preview
  | Some summary -> row.preview ^ " " ^ receipt_detail summary
;;

let render ~now ?(receipt = fun _ -> None) { listed; later } =
  match listed with
  | [] -> None
  | _ :: _ ->
    let arrived = List.length listed + later in
    let has_steer =
      List.exists (fun (row : row) -> row.mode = Steer) listed
    in
    let lines =
      List.map
        (fun (row : row) ->
           Printf.sprintf
             "- %s [%s], %s ago: %s"
             (urgency_text row.urgency)
             (inbound_queue_mode_to_string row.mode)
             (Keeper_age_text.of_seconds (now -. row.arrived_at))
             (line_text ~receipt row))
        listed
    in
    let steer_cue =
      if has_steer
      then [ "Steer arrivals were surfaced at this tool boundary; adjust or conclude this turn promptly." ]
      else []
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
          @ steer_cue
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

let block ?receipt tracker ~now ~read ~on_unavailable =
  match read () with
  | Error detail ->
    on_unavailable detail;
    None
  | Ok selections -> render ~now ?receipt (next tracker selections)
;;

type claim =
  { round : round
  ; text : string
  ; confirm : unit -> unit
  }

let claim ?receipt tracker ~now ~read ~on_unavailable =
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
      (render ~now ?receipt round)
;;
