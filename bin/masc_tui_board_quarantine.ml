module Command = Masc.Keeper_board_attention_quarantine_command
module Candidate = Masc.Keeper_board_attention_candidate
module Terminal_text = Masc_tui_ansi.Terminal_text

type row =
  | Item of Command.inventory_item
  | Unreadable_row of string

type t =
  { rows : row list
  ; errors : Command.inventory_error list
  ; unreadable_errors : string list
  }

let decode json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "items" fields, List.assoc_opt "errors" fields with
     | Some (`List items), Some (`List errors) ->
       let rows =
         List.map
           (fun item ->
              match Command.inventory_item_of_json item with
              | Ok item -> Item item
              | Error detail -> Unreadable_row detail)
           items
       in
       let errors, unreadable_errors =
         List.partition_map
           (fun error ->
              match Command.inventory_error_of_json error with
              | Ok error -> Either.Left error
              | Error detail -> Either.Right detail)
           errors
       in
       Ok { rows; errors; unreadable_errors }
     | _ -> Error "board quarantines: items and errors must be lists")
  | _ -> Error "board quarantines: body must be an object"
;;

type tone =
  | Plain
  | Dim
  | Warn
  | Bad

let category_words : Candidate.quarantine_failure_category -> string = function
  | Candidate.Exact_execution_quarantined ->
    "stopped mid-judgment at a restart (the call may already have gone out)"
  | Candidate.Candidate_membership_conflict -> "candidate belongs to another partition"
  | Candidate.Durable_partition_invariant -> "partition ledger contradicts itself"
  | Candidate.Exact_setup_unavailable -> "judgment lane could not be set up"
  | Candidate.Exact_flow_replayed -> "judgment was replayed"
  | Candidate.Exact_execution_terminal -> "judgment call ended without an answer"
  | Candidate.Domain_output_invalid -> "judge answered in a shape it may not"
  | Candidate.Execution_provenance_mismatch -> "answer came from a different call"
  | Candidate.Unexpected_worker_failure -> "worker failed unexpectedly"
;;

let awaits_operator (item : Command.inventory_item) =
  match item.Command.phase with
  | Command.Inventory_quarantined | Command.Inventory_requeue_requested -> true
  | Command.Inventory_requeued -> false
;;

let items (quarantines : t) =
  List.filter_map
    (function
      | Item item -> Some item
      | Unreadable_row _ -> None)
    quarantines.rows
;;

let compare_oldest (left : Command.inventory_item) (right : Command.inventory_item) =
  match Float.compare left.Command.quarantined_at right.Command.quarantined_at with
  | 0 -> String.compare left.Command.partition_id right.Command.partition_id
  | order -> order
;;

let waiting quarantines =
  items quarantines |> List.filter awaits_operator |> List.sort compare_oldest
;;

let oldest_waiting quarantines =
  match waiting quarantines with
  | oldest :: _ -> Some oldest
  | [] -> None
;;

let requeue_request (item : Command.inventory_item) : Command.request =
  { Command.candidate_id = item.Command.candidate_id
  ; expected_quarantine_id = item.Command.quarantine_id
  ; decision = Command.Acknowledge_and_requeue
  }
;;

let seconds_per_minute = 60
let seconds_per_hour = 3600
let seconds_per_day = 86400

(* The same span words the roster uses for an idle lane. *)
let span_words seconds =
  let seconds = max 0 seconds in
  if seconds < seconds_per_minute then Printf.sprintf "%ds" seconds
  else if seconds < seconds_per_hour then
    Printf.sprintf "%dm" (seconds / seconds_per_minute)
  else if seconds < seconds_per_day then
    Printf.sprintf "%dh" (seconds / seconds_per_hour)
  else Printf.sprintf "%dd" (seconds / seconds_per_day)
;;

let unreadable_rows (quarantines : t) =
  List.filter_map
    (function
      | Unreadable_row detail -> Some detail
      | Item _ -> None)
    quarantines.rows
;;

let lines ~now fetched ~keeper_name =
  match Masc_tui_fetched.view_for ~equal:String.equal fetched ~key:keeper_name with
  | Masc_tui_fetched.Absent -> [ Dim, "not read yet" ]
  | Masc_tui_fetched.Loading -> [ Dim, "reading\xe2\x80\xa6" ]
  | Masc_tui_fetched.Failed detail ->
    [ Bad, "could not read: " ^ Terminal_text.single_line detail ]
  | Masc_tui_fetched.Ready quarantines ->
    let waiting_items = waiting quarantines in
    let summary =
      match waiting_items with
      | [] -> [ Dim, "nothing blocked" ]
      | _ :: _ ->
        [ ( Warn
          , Printf.sprintf
              "%d blocked, waiting for an operator \xc2\xb7 Q requeues the oldest"
              (List.length waiting_items) )
        ]
    in
    let item_lines =
      List.map
        (fun (item : Command.inventory_item) ->
           let age =
             span_words (Float.to_int (now -. item.Command.quarantined_at))
           in
           let asked =
             match item.Command.phase with
             | Command.Inventory_requeue_requested -> " \xc2\xb7 requeue asked, not finished"
             | Command.Inventory_quarantined | Command.Inventory_requeued -> ""
           in
           ( Plain
           , Printf.sprintf "%s ago \xc2\xb7 %s%s \xc2\xb7 %s" age
               (category_words item.Command.failure_category)
               asked
               (Terminal_text.single_line item.Command.partition_id) ))
        waiting_items
    in
    let requeued =
      List.length (List.filter (fun item -> not (awaits_operator item)) (items quarantines))
    in
    let requeued_lines =
      if requeued = 0 then []
      else [ Dim, Printf.sprintf "%d requeued, back with the worker" requeued ]
    in
    let unreadable = unreadable_rows quarantines @ quarantines.unreadable_errors in
    let unreadable_lines =
      match unreadable with
      | [] -> []
      | first :: _ ->
        [ ( Bad
          , Printf.sprintf "%d row(s) this TUI cannot read: %s"
              (List.length unreadable)
              (Terminal_text.single_line first) )
        ]
    in
    let ledger_lines =
      List.map
        (fun (error : Command.inventory_error) ->
           match error.Command.kind with
           | Command.Inventory_candidate_ledger_unavailable ->
             ( Bad
             , "candidate ledger unreadable for "
               ^ Terminal_text.single_line error.Command.keeper_name ))
        quarantines.errors
    in
    summary @ item_lines @ requeued_lines @ unreadable_lines @ ledger_lines
;;
