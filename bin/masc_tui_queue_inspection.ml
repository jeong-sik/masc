type action = Inspect | Pause | Resume | Cancel of string | Move_to_end of string | Edit of string * string
  | Cancel_event of string * int64 * string
  | Prioritize_event of string * int64 * Keeper_event_queue.urgency
let ( let* ) = Result.bind
let split text =
  let text = String.trim text in
  match String.index_opt text ' ' with
  | None -> text, ""
  | Some i -> String.sub text 0 i, String.trim (String.sub text (i + 1) (String.length text - i - 1))
let parse text =
  match split text with
  | "", "" -> Ok Inspect
  | "pause", "" -> Ok Pause
  | "resume", "" -> Ok Resume
  | ("cancel" | "last" as verb), id when id <> "" ->
    let* id = Keeper_chat_operation.Operation_id.of_string id in
    let id = Keeper_chat_operation.Operation_id.to_string id in
    Ok (if verb = "cancel" then Cancel id else Move_to_end id)
  | ("cancel-event" | "priority-event" as verb), rest ->
    let source_ref, rest = split rest in
    let incarnation, value = split rest in
    let* incarnation = match Int64.of_string_opt incarnation with
      | Some n when n >= 0L -> Ok n
      | _ -> Error "Event incarnation must be a non-negative integer from /queue" in
    if source_ref = "" || value = "" then Error "Event action requires REF INCARNATION and reason or urgency"
    else if verb = "cancel-event" then Ok (Cancel_event (source_ref, incarnation, value))
    else let* urgency = Keeper_event_queue.urgency_of_string value in
      Ok (Prioritize_event (source_ref, incarnation, urgency))
  | "edit", rest ->
    let id, message = split rest in
    let* id = Keeper_chat_operation.Operation_id.of_string id in
    if message = "" then Error "/queue edit requires the new message"
    else Ok (Edit (Keeper_chat_operation.Operation_id.to_string id, message))
  | _ -> Error "Use /queue, /queue pause, /queue resume, /queue cancel ID, /queue last ID, /queue edit ID message"
let field key = function
  | `Assoc fields -> (match List.assoc_opt key fields with Some value -> Ok value | None -> Error ("Queue response missing " ^ key))
  | _ -> Error "Queue response must be an object"
let string key json =
  let* value = field key json in
  match value with `String value -> Ok value | _ -> Error ("Queue field must be text: " ^ key)
let list key json =
  let* value = field key json in
  match value with `List values -> Ok values | _ -> Error ("Queue field must be a list: " ^ key)
let rec map_result f = function
  | [] -> Ok []
  | x :: xs -> let* value = f x in let* rest = map_result f xs in Ok (value :: rest)
let safe = Masc.Tui_terminal_text.sanitize_terminal_text
(* The snapshot used to print one row per pending stimulus as
   "source: what — next_action" plus a 64-hex address, in queue order, with no
   clock: 31 occurrences of one schedule were 62 lines that read the same. The
   row now opens with when the thing arrived, names its lifecycle, and
   a schedule's pending occurrences -- one row from the server since the
   inventory groups them -- show their count and the span of their due
   instants. The exact address stays on its own line because it is the
   argument /queue cancel-event and priority-event take. *)
let clock_text at =
  let time = Unix.localtime at in
  Printf.sprintf "%02d:%02d" time.Unix.tm_hour time.Unix.tm_min

module Inventory = Masc.Server_keeper_waiting_inventory

let optional_timestamp key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | None | Some `Null -> Ok None
     | Some (`Float value) when Float.is_finite value -> Ok (Some value)
     | Some (`Int value) -> Ok (Some (float_of_int value))
     | Some _ -> Error ("Queue timestamp must be finite: " ^ key))
  | _ -> Error "Queue row must be an object"

let count_field ?default key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields, default with
     | Some (`Int count), _ when count >= 0 -> Ok count
     | None, Some count -> Ok count
     | Some _, _ | None, None -> Error ("Queue count must be a non-negative integer: " ^ key))
  | _ -> Error "Queue row detail must be an object"

type row_phase = Pending | Running | Scheduled of float | Due of float | Settling | Terminal | Unavailable

type inventory_row =
  { source : Inventory.waiting_source
  ; count : int
  ; phase : row_phase
  ; line : string
  }

let row_phase ~now source row detail =
  match (source : Inventory.waiting_source) with
  | Event_queue_pending | Chat_operation_queued | Hitl_pending | Operator_pending_confirm -> Ok Pending
  | Chat_operation_running | Fusion_running -> Ok Running
  | Owner_shutdown -> Ok Settling
  | Read_error -> Ok Unavailable
  | Schedule_waiting ->
    let* status = string "status" detail in
    let* status = Schedule_domain.schedule_status_of_string status in
    let due () =
      let* due = optional_timestamp "due_at" row in
      match due with
      | None -> Error "Scheduled inventory row has no due_at"
      | Some at -> Ok at in
    (match status with
     | Schedule_domain.Running -> Ok Running
     | Succeeded | Failed | Cancelled | Expired -> Ok Terminal
     | Scheduled -> let* at = due () in Ok (if at > now then Scheduled at else Due at)
     | Due -> let* at = due () in Ok (Due at))

let waiting_text ~now since =
  match Masc_tui_message_layout.age_text ~now ~since with
  | Some age -> " · waiting " ^ age
  | None -> ""

let describe_row ~now row =
  let* source = string "source" row in
  let* source = Inventory.source_of_string source in
  let* what = string "what" row in
  let* detail = field "detail" row in
  let* count = match source with
    | Inventory.Chat_operation_queued -> count_field "queued_count" detail
    | Event_queue_pending -> count_field ~default:1 "group_count" detail
    | Chat_operation_running | Hitl_pending | Fusion_running | Schedule_waiting
    | Owner_shutdown | Operator_pending_confirm | Read_error -> Ok 1 in
  let* phase = row_phase ~now source row detail in
  let* since = optional_timestamp "since" row in
  let clock = match since with Some at -> clock_text at ^ "  " | None -> "       " in
  let* first_due = optional_timestamp "group_first_due_unix" detail in
  let* last_due = optional_timestamp "group_last_due_unix" detail in
  let span = match first_due, last_due with
    | Some first, Some last when count > 1 ->
      Printf.sprintf " · due %s \xe2\x86\x92 %s" (clock_text first) (clock_text last)
    | Some _, Some _ | None, None | Some _, None | None, Some _ -> "" in
  let timing = match phase with
    | Pending when source = Inventory.Event_queue_pending ->
      Option.bind since (fun since -> Masc_tui_message_layout.age_text ~now ~since)
      |> Option.fold ~none:" · unacknowledged" ~some:(fun age -> " · unacknowledged " ^ age)
    | Pending -> Option.fold ~none:"" ~some:(waiting_text ~now) since
    | Scheduled at -> " · scheduled for " ^ Masc_domain.iso8601_of_unix_seconds at
    | Due at -> " · due " ^ Masc_domain.iso8601_of_unix_seconds at
    | Running -> " · running"
    | Settling -> " · settling"
    | Terminal -> " · terminal"
    | Unavailable -> " · unavailable" in
  let address = match detail with
    | `Assoc fields -> (match List.assoc_opt "source_ref" fields, List.assoc_opt "source_incarnation" fields with
        | Some (`String reference), Some (`String incarnation) ->
          let more = if count > 1 then Printf.sprintf " \xc2\xb7 +%d more" (count - 1) else "" in
          "\n         event " ^ safe reference ^ " " ^ safe incarnation ^ more
        | Some _, Some _ | Some _, None | None, Some _ | None, None -> "")
    | _ -> "" in
  Ok { source; count; phase;
       line = Printf.sprintf "  %s%s%s%s%s" clock (safe what) span timing address }

let inventory_counts described =
    let count_phase matches =
      List.fold_left (fun total row -> if matches row.phase then total + row.count else total) 0 described in
    let pending = count_phase (function Pending -> true | Running | Scheduled _ | Due _ | Settling | Terminal | Unavailable -> false) in
      [ "running", count_phase (function Running -> true | Pending | Scheduled _ | Due _ | Settling | Terminal | Unavailable -> false)
      ; "scheduled", count_phase (function Scheduled _ -> true | Pending | Running | Due _ | Settling | Terminal | Unavailable -> false)
      ; "due", count_phase (function Due _ -> true | Pending | Running | Scheduled _ | Settling | Terminal | Unavailable -> false)
      ; "settling", count_phase (function Settling -> true | Pending | Running | Scheduled _ | Due _ | Terminal | Unavailable -> false)
      ; "terminal", count_phase (function Terminal -> true | Pending | Running | Scheduled _ | Due _ | Settling | Unavailable -> false)
      ; "unavailable", count_phase (function Unavailable -> true | Pending | Running | Scheduled _ | Due _ | Settling | Terminal -> false)
      ]
      |> List.filter (fun (_, count) -> count > 0)
      |> List.map (fun (label, count) -> Printf.sprintf "%d %s" count label)
      |> List.cons (Printf.sprintf "%d pending" pending)
      |> String.concat " · "

let waiting_lines ~now json =
  let* keepers = list "keepers" json in
  let* global_rows = list "global_waiting_on" json in
  let* global = map_result (describe_row ~now) global_rows in
  let* groups = map_result (fun keeper ->
    let* state = string "state" keeper in
    let* paused = field "paused" keeper in
    let* consumption = match paused with
      | `Bool true -> Ok "paused"
      | `Bool false -> Ok "open"
      | `Null -> Ok "unknown"
      | _ -> Error "Queue paused field must be boolean or null" in
    let* rows = list "waiting_on" keeper in
    let* described = map_result (describe_row ~now) rows in
    let counts = inventory_counts described in
    let header =
      Printf.sprintf "Queue consumption: %s; inventory: %s \xc2\xb7 %s in %d %s"
        consumption (safe state) counts (List.length described)
        (if List.length described = 1 then "group" else "groups") in
    (* The autonomous lane is what drains the event queue, and it does not
       run while an operator chat holds the turn slot. Said once, above the
       rows it explains, only when both are on the screen. *)
    let has_events = List.exists (fun row -> row.source = Inventory.Event_queue_pending) described in
    let blocker =
      let chat_running = List.exists (fun row -> row.source = Inventory.Chat_operation_running) described in
      if has_events && chat_running then
        [ "  autonomous turn: waits while the chat operation holds the turn slot" ]
      else [] in
    let event_note = if has_events then
        [ "  pending events are unacknowledged; they may already be in the current turn" ]
      else [] in
    Ok (header :: blocker @ event_note @ List.map (fun row -> row.line) described)) keepers in
  let global_lines = match global with
    | [] -> []
    | rows -> ("Workspace inventory: " ^ inventory_counts rows)
        :: List.map (fun row -> row.line) rows in
  Ok (global_lines @ List.concat groups)
let operation_lines json =
  let* operations = list "operations" json in
  let* lines = map_result (fun operation ->
    let* id = string "operation_id" operation in
    let* source = field "source" operation in
    let* source = Masc.Keeper_chat_operation_payload.source_of_json source in
    let* input = field "input" operation in
    let* input = Masc.Keeper_chat_operation_payload.input_of_json input in
    Ok (Printf.sprintf "  %s [%s / %s]\n    %s" (safe id) (safe (Keeper_continuation_channel.describe source.continuation_channel))
      (safe source.submitted_by) (safe input.message))) operations in
  Ok ((Printf.sprintf "Server queued messages: %d" (List.length operations)) :: lines)
let edited_input ~message operation =
  let* input = field "input" operation in
  let* input = Masc.Keeper_chat_operation_payload.input_of_json input in
  let media = List.filter (function Masc.Keeper_multimodal_input.User_text _ -> false | _ -> true) input.user_blocks in
  Ok (Masc.Keeper_chat_operation_payload.input_to_json ~message
    ~user_blocks:(Masc.Keeper_multimodal_input.User_text message :: media)
    ~turn_instructions:input.turn_instructions ~surface_context:input.surface_context ~attachments:input.attachments)

let next_sequence json =
  let* operations = list "operations" json in
  match List.rev operations with
  | [] -> Ok None
  | last :: _ ->
    let* sequence = string "sequence" last in
    match Int64.of_string_opt sequence with
    | Some sequence when sequence >= 0L -> Ok (Some (Int64.to_string sequence))
    | _ -> Error "Queue sequence must be a non-negative integer"
