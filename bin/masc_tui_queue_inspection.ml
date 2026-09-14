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
let safe = Masc.Tui_decode.sanitize_terminal_text
(* The snapshot used to print one row per pending stimulus as
   "source: what — next_action" plus a 64-hex address, in queue order, with no
   clock: 31 occurrences of one schedule were 62 lines that read the same. The
   row now opens with when the thing arrived, says how long it has waited, and
   a schedule's pending occurrences -- one row from the server since the
   inventory groups them -- show their count and the span of their due
   instants. The exact address stays on its own line because it is the
   argument /queue cancel-event and priority-event take. *)
let clock_text at =
  let time = Unix.localtime at in
  Printf.sprintf "%02d:%02d" time.Unix.tm_hour time.Unix.tm_min

let float_field key json =
  match field key json with
  | Ok (`Float value) -> Some value
  | Ok (`Int value) -> Some (float_of_int value)
  | Ok _ | Error _ -> None

let int_field key json =
  match field key json with
  | Ok (`Int value) -> Some value
  | Ok _ | Error _ -> None

let waiting_text ~now since =
  match Masc_tui_message_layout.age_text ~now ~since with
  | Some age -> " · waiting " ^ age
  | None -> ""

let waiting_lines ~now json =
  let* keepers = list "keepers" json in
  let* groups = map_result (fun keeper ->
    let* state = string "state" keeper in
    let* paused = field "paused" keeper in
    let* consumption = match paused with
      | `Bool true -> Ok "paused"
      | `Bool false -> Ok "open"
      | `Null -> Ok "unknown"
      | _ -> Error "Queue paused field must be boolean or null" in
    let* rows = list "waiting_on" keeper in
    let* described = map_result (fun row ->
      let* source = string "source" row in
      let* what = string "what" row in
      let* detail = field "detail" row in
      let since = float_field "since" row in
      let count = Option.value (int_field "group_count" detail) ~default:1 in
      let clock = match since with Some at -> clock_text at ^ "  " | None -> "       " in
      let span =
        match float_field "group_first_due_unix" detail, float_field "group_last_due_unix" detail with
        | Some first, Some last when count > 1 ->
          Printf.sprintf " · due %s \xe2\x86\x92 %s" (clock_text first) (clock_text last)
        | _ -> "" in
      let waiting = match since with Some at -> waiting_text ~now at | None -> "" in
      let address = match detail with
        | `Assoc fields -> (match List.assoc_opt "source_ref" fields, List.assoc_opt "source_incarnation" fields with
            | Some (`String reference), Some (`String incarnation) ->
              let more = if count > 1 then Printf.sprintf " \xc2\xb7 +%d more" (count - 1) else "" in
              "\n         event " ^ safe reference ^ " " ^ safe incarnation ^ more
            | _ -> "")
        | _ -> "" in
      Ok (source, count, since, Printf.sprintf "  %s%s%s%s%s" clock (safe what) span waiting address)) rows in
    let pending = List.fold_left (fun total (_, count, _, _) -> total + count) 0 described in
    let header =
      Printf.sprintf "Queue consumption: %s; server work: %s \xc2\xb7 %d pending in %d %s"
        consumption (safe state) pending (List.length described)
        (if List.length described = 1 then "group" else "groups") in
    (* The autonomous lane is what drains the event queue, and it does not
       run while an operator chat holds the turn slot. Said once, above the
       rows it explains, only when both are on the screen. *)
    let blocker =
      let has_pending = List.exists (fun (source, _, _, _) -> source = "event_queue_pending") described in
      match List.find_opt (fun (source, _, _, _) -> source = "chat_operation_running") described with
      | Some (_, _, since, _) when has_pending ->
        let since_text = match since with Some at -> " (chat since " ^ clock_text at ^ ")" | None -> "" in
        [ "  autonomous turn: waits while the operator chat runs" ^ since_text ]
      | Some _ | None -> [] in
    Ok (header :: blocker @ List.map (fun (_, _, _, line) -> line) described)) keepers in
  Ok (List.concat groups)
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
