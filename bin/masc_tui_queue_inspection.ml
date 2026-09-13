type action = Inspect | Pause | Resume | Cancel of string | Move_to_end of string | Edit of string * string
  | Cancel_event of string * int64 * string
  | Prioritize_event of string * int64 * Masc.Keeper_event_queue.urgency
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
    let* id = Masc.Keeper_chat_operation.Operation_id.of_string id in
    let id = Masc.Keeper_chat_operation.Operation_id.to_string id in
    Ok (if verb = "cancel" then Cancel id else Move_to_end id)
  | ("cancel-event" | "priority-event" as verb), rest ->
    let source_ref, rest = split rest in
    let incarnation, value = split rest in
    let* incarnation = match Int64.of_string_opt incarnation with
      | Some n when n >= 0L -> Ok n
      | _ -> Error "Event incarnation must be a non-negative integer from /queue" in
    if source_ref = "" || value = "" then Error "Event action requires REF INCARNATION and reason or urgency"
    else if verb = "cancel-event" then Ok (Cancel_event (source_ref, incarnation, value))
    else let* urgency = Masc.Keeper_event_queue.urgency_of_string value in
      Ok (Prioritize_event (source_ref, incarnation, urgency))
  | "edit", rest ->
    let id, message = split rest in
    let* id = Masc.Keeper_chat_operation.Operation_id.of_string id in
    if message = "" then Error "/queue edit requires the new message"
    else Ok (Edit (Masc.Keeper_chat_operation.Operation_id.to_string id, message))
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
let waiting_lines json =
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
    let* lines = map_result (fun row ->
      let* source = string "source" row in
      let* what = string "what" row in
      let* next = string "next_action" row in
      let* detail = field "detail" row in
      let event_identity = match detail with
        | `Assoc fields -> (match List.assoc_opt "source_ref" fields, List.assoc_opt "source_incarnation" fields with
            | Some (`String reference), Some (`String incarnation) ->
              "\n    event " ^ safe reference ^ " " ^ safe incarnation
            | _ -> "")
        | _ -> "" in
      Ok (Printf.sprintf "  %s: %s — %s%s" (safe source) (safe what) (safe next) event_identity)) rows in
    Ok (("Queue consumption: " ^ consumption ^ "; server work: " ^ safe state ^ " (" ^ string_of_int (List.length rows) ^ " groups)") :: lines)) keepers in
  Ok (List.concat groups)
let operation_lines json =
  let* operations = list "operations" json in
  let* lines = map_result (fun operation ->
    let* id = string "operation_id" operation in
    let* source = field "source" operation in
    let* source = Masc.Keeper_chat_operation_payload.source_of_json source in
    let* input = field "input" operation in
    let* input = Masc.Keeper_chat_operation_payload.input_of_json input in
    Ok (Printf.sprintf "  %s [%s / %s]\n    %s" (safe id) (safe (Masc.Keeper_continuation_channel.describe source.continuation_channel))
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
