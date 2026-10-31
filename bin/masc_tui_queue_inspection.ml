type action = Inspect | Pause | Resume | Clear | Cancel of string | Move_to_end of string | Run_next of string | Edit of string * string
  | Cancel_event of string * int64 * string
  | Prioritize_event of string * int64 * Keeper_event_queue.urgency
  | Inspect_peers of unit ref * string option

type peer_relation = {
  operation_id : string;
  sender : string;
  recipient : string;
  reply_to : string option;
}
type peer_snapshot = { queued_count : int; relations : peer_relation list }
type peer_page = { snapshot : peer_snapshot; next_sequence : string option }

type item_id =
  | Local_message of string | Server_message of string | Running_message of string
  | Event of string * int64 | Schedule of string * string
type item = { id : item_id option; text : string }
type observation = {
  waiting : (item list, string) result;
  operations : (item list, string) result;
  peer_page : peer_page option;
}
open Result.Syntax
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
  | "clear", "" -> Ok Clear
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
  | _ -> Error ("Use " ^ Masc_tui_command.usage Masc_tui_command.queue_help)
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

module Operation_ids = Set.Make (String)

let peer_snapshot ~keeper_name json =
  let* operations = list "operations" json in
  let* decoded = map_result (fun operation ->
    let* id = string "operation_id" operation in
    let* id = Keeper_chat_operation.Operation_id.of_string id in
    let operation_id = Keeper_chat_operation.Operation_id.to_string id in
    let* state = string "state" operation in
    let* () = if String.equal state "Queued" then Ok ()
      else Error "Queue response contains an operation that is not queued" in
    let* source = field "source" operation in
    let* source = Masc.Keeper_chat_operation_payload.source_of_json source in
    let reply_to = match source.continuation_channel with
      | Keeper_continuation_channel.Keeper { keeper_name } -> Some keeper_name
      | Dashboard _ | Discord _ | Slack _ | Telegram _ | Imessage _ | Unrouted _ -> None in
    Ok (operation_id, Option.map (fun sender ->
      { operation_id;
        sender = Masc.Keeper_identity.Keeper_id.to_string sender;
        recipient = keeper_name; reply_to }) source.sender_keeper)) operations in
  let rec unique seen relations = function
    | [] -> Ok (List.rev relations)
    | (id, relation) :: rest ->
        if Operation_ids.mem id seen then
          Error "Queue response contains a duplicate operation ID; reopen to read it again"
        else
          unique (Operation_ids.add id seen)
            (match relation with Some value -> value :: relations | None -> relations) rest in
  let* relations = unique Operation_ids.empty [] decoded in
  Ok { queued_count = List.length operations; relations }

let next_sequence_after ~after_sequence json =
  let* operations = list "operations" json in
  let* previous = match after_sequence with
    | None -> Ok None
    | Some raw ->
        (match Int64.of_string_opt raw with
         | Some sequence when sequence >= 0L -> Ok (Some sequence)
         | Some _ | None -> Error "Queue sequence must be a non-negative integer") in
  let rec walk previous last = function
    | [] -> Ok (Option.map Int64.to_string last)
    | operation :: rest ->
        let* raw = string "sequence" operation in
        let* sequence = match Int64.of_string_opt raw with
          | Some sequence when sequence >= 0L -> Ok sequence
          | Some _ | None -> Error "Queue sequence must be a non-negative integer" in
        (match previous with
         | Some boundary when sequence <= boundary -> Error "Queue pagination did not advance"
         | Some _ | None -> walk (Some sequence) (Some sequence) rest)
  in
  walk previous None operations

let next_sequence json = next_sequence_after ~after_sequence:None json

let read_peer_page ~keeper_name ~after_sequence ~read_page =
  let* page = read_page () in
  let* snapshot = peer_snapshot ~keeper_name page in
  let* next_sequence = next_sequence_after ~after_sequence page in
  Ok { snapshot; next_sequence }

let peer_lines ~page_number { snapshot; next_sequence } =
  let scope = Printf.sprintf "Page %d · observed %d queued requests; %d from Keepers"
      page_number
      snapshot.queued_count (List.length snapshot.relations) in
  let lines = List.map (fun relation ->
    Printf.sprintf "%s → %s · queued · %s%s"
      (safe relation.sender) (safe relation.recipient) (safe relation.operation_id)
      (Option.fold ~none:"" ~some:(fun keeper -> " · reply route " ^ safe keeper) relation.reply_to))
    snapshot.relations in
  let next = match next_sequence with
    | Some _ -> "> reads later queued requests"
    | None when page_number = 1 -> "No queued requests in this read"
    | None -> "No requests after this cursor in this read" in
  scope :: (("< previous · " ^ next ^ " · r refresh/retry · R start over. Pages are separate observations; running and completed requests are not listed.") :: lines)

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
  Ok { source; count; phase;
       line = Printf.sprintf "  %s%s%s%s" clock (safe what) span timing }

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

let first_line text =
  match String.index_opt text '\n' with
  | None -> text
  | Some index -> String.sub text 0 index

let inventory_item row described =
  let detail = match row with
    | `Assoc fields -> (match List.assoc_opt "detail" fields with
        | Some (`Assoc fields) -> fields | Some _ | None -> [])
    | _ -> [] in
  let text key = match List.assoc_opt key detail with
    | Some (`String value) when value <> "" -> Some value
    | Some _ | None -> None in
  let id = match described.source with
    | Inventory.Event_queue_pending ->
      (match described.phase with
       | Pending when described.count = 1 ->
         (match text "source_ref", text "source_incarnation" with
          | Some reference, Some incarnation ->
            (match Int64.of_string_opt incarnation with
             | Some revision when revision >= 0L -> Some (Event (reference, revision))
             | Some _ | None -> None)
          | Some _, None | None, Some _ | None, None -> None)
       | Pending | Running | Scheduled _ | Due _ | Settling | Terminal | Unavailable -> None)
    | Inventory.Chat_operation_running ->
      Option.map (fun id -> Running_message id) (text "operation_id")
    | Inventory.Schedule_waiting ->
      (match text "schedule_id", text "schedule_instance_id" with
       | Some id, Some instance -> Some (Schedule (id, instance))
       | Some _, None | None, Some _ | None, None -> None)
    | Inventory.Chat_operation_queued | Inventory.Hitl_pending | Inventory.Fusion_running
    | Inventory.Owner_shutdown | Inventory.Operator_pending_confirm | Inventory.Read_error -> None in
  { id; text = first_line described.line }

let inventory_items row described =
  let summary = inventory_item row described in
  let members = match described.source with
    | Inventory.Event_queue_pending when described.count > 1 ->
      (match row with
       | `Assoc fields ->
         (match List.assoc_opt "detail" fields with
          | Some (`Assoc detail) ->
            (match List.assoc_opt "group_members" detail with
             | Some (`List members) -> Some members
             | Some _ | None -> None)
          | Some _ | None -> None)
       | _ -> None)
    | Inventory.Event_queue_pending | Inventory.Chat_operation_queued
    | Inventory.Chat_operation_running | Inventory.Hitl_pending | Inventory.Fusion_running
    | Inventory.Schedule_waiting | Inventory.Owner_shutdown
    | Inventory.Operator_pending_confirm | Inventory.Read_error -> None in
  match members with
  | None ->
    (match described.source with
     | Inventory.Event_queue_pending when described.count > 1 ->
       [summary; {id=None; text="  Individual event identities are unavailable"}]
     | Inventory.Event_queue_pending | Inventory.Chat_operation_queued
     | Inventory.Chat_operation_running | Inventory.Hitl_pending | Inventory.Fusion_running
     | Inventory.Schedule_waiting | Inventory.Owner_shutdown
     | Inventory.Operator_pending_confirm | Inventory.Read_error -> [summary])
  | Some values ->
    let parse_member = function
      | `Assoc fields ->
        (match List.assoc_opt "source_ref" fields, List.assoc_opt "source_incarnation" fields with
         | Some (`String reference), Some (`String incarnation) when reference <> "" ->
           (match Int64.of_string_opt incarnation with
            | Some revision when revision >= 0L ->
              (match optional_timestamp "due_at_unix" (`Assoc fields) with
               | Ok due -> Some (reference, revision, due)
               | Error _ -> None)
            | Some _ | None -> None)
         | Some _, Some _ | Some _, None | None, Some _ | None, None -> None)
      | _ -> None in
    let addresses = List.filter_map parse_member values in
    let identities = List.map (fun (reference, revision, _) -> reference, revision) addresses in
    if List.length values <> described.count || List.length addresses <> described.count
       || List.length (List.sort_uniq compare identities) <> described.count then
      [summary; {id=None; text="  Group member identities unavailable; refresh before changing them"}]
    else summary :: List.mapi (fun index (reference, revision, due) ->
      {id=Some (Event (reference, revision));
       text=Printf.sprintf "    occurrence %d/%d%s · %s"
         (index + 1) described.count
         (Option.fold ~none:"" ~some:(fun at -> " · due " ^ Masc_domain.iso8601_of_unix_seconds at) due)
         (first_line described.line)}) addresses

let waiting_items ~now json =
  let* keepers = list "keepers" json in
  let* global_rows = list "global_waiting_on" json in
  let describe rows = map_result (fun row ->
    let* described = describe_row ~now row in
    Ok (described, inventory_items row described)) rows in
  let* global = describe global_rows in
  let* groups = map_result (fun keeper ->
    let* state = string "state" keeper in
    let* paused = field "paused" keeper in
    let* consumption = match paused with
      | `Bool true -> Ok "paused" | `Bool false -> Ok "open" | `Null -> Ok "unknown"
      | _ -> Error "Queue paused field must be boolean or null" in
    let* rows = list "waiting_on" keeper in
    let* rows = describe rows in
    let described = List.map fst rows in
    let header = {id=None; text=Printf.sprintf "Queue %s · %s · %s"
      consumption (safe state) (inventory_counts described)} in
    let has_events = List.exists (fun row -> row.source = Inventory.Event_queue_pending) described in
    let chat_running = List.exists (fun row -> row.source = Inventory.Chat_operation_running) described in
    let notes =
      (if has_events && chat_running then
         [{id=None; text="Events wait while the current chat holds the turn"}] else []) @
      (if has_events then
         [{id=None; text="Pending events may already be in the current turn"}] else []) in
    Ok (header :: notes @ List.concat_map snd rows)) keepers in
  let global_items = match global with
    | [] -> []
    | rows -> {id=None; text="Workspace inventory · " ^ inventory_counts (List.map fst rows)}
      :: List.concat_map (fun (_, items) -> List.map (fun item -> {item with id=None}) items) rows in
  Ok (global_items @ List.concat groups)

let operation_items json =
  let* operations = list "operations" json in
  let module Input = Masc.Keeper_multimodal_input in
  let media kind (block : Input.user_media_block) =
    Printf.sprintf "%s: %s · %s · id %s" kind (safe block.name)
      (safe block.mime_type) (safe block.attachment_id) in
  let content = function
    | Input.User_text text -> "text: " ^ Masc.Tui_terminal_text.sanitize_terminal_lines text
    | User_image (Attached block) -> media "image" block
    | User_image (Url_ref reference) -> "image URL: " ^ safe reference.value
    | User_image (File_id_ref reference) -> "image file: " ^ safe reference.value
    | User_document block -> media "document" block
    | User_audio block -> media "audio" block in
  let* rows = map_result (fun operation ->
    let* id = string "operation_id" operation in
    let* id = Keeper_chat_operation.Operation_id.of_string id in
    let* source = field "source" operation in
    let* source = Masc.Keeper_chat_operation_payload.source_of_json source in
    let* input = field "input" operation in
    let* input = Masc.Keeper_chat_operation_payload.input_of_json input in
    let blocks = match input.user_blocks with
      | [] -> ""
      | blocks -> "\n\nInput blocks:\n" ^ String.concat "\n" (List.map content blocks) in
    let attachments = match input.attachments with
      | [] -> ""
      | attachments ->
        "\n\nAttachments:\n" ^ String.concat "\n" (List.map
          (fun (attachment : Masc.Keeper_chat_store.attachment) ->
            Printf.sprintf "%s · %s · %d bytes · id %s" (safe attachment.name)
              (safe attachment.mime_type) attachment.size (safe attachment.id)) attachments) in
    Ok {id=Some (Server_message (Keeper_chat_operation.Operation_id.to_string id));
        text=Printf.sprintf "  %s · %s: %s%s%s"
          (safe (Keeper_continuation_channel.describe source.continuation_channel))
          (safe source.submitted_by) (Masc.Tui_terminal_text.sanitize_terminal_lines input.message)
          blocks attachments}) operations in
  let ids = List.filter_map (fun item -> match item.id with
    | Some (Server_message id) -> Some id
    | Some (Local_message _ | Running_message _ | Event _ | Schedule _) | None -> None) rows in
  if List.length (List.sort_uniq String.compare ids) <> List.length ids then
    Error "Server queue changed while reading pages; refresh to try again"
  else Ok ({id=None; text=Printf.sprintf "Server queued messages · %d" (List.length rows)} :: rows)
let edited_input ~message operation =
  let* input = field "input" operation in
  let* input = Masc.Keeper_chat_operation_payload.input_of_json input in
  let media = List.filter (function
    | Masc.Keeper_multimodal_input.User_text _ -> false
    | Masc.Keeper_multimodal_input.User_image _ | User_document _ | User_audio _ -> true) input.user_blocks in
  Ok (Masc.Keeper_chat_operation_payload.input_to_json ~message
    ~user_blocks:(Masc.Keeper_multimodal_input.User_text message :: media)
    ~turn_instructions:input.turn_instructions ~surface_context:input.surface_context ~attachments:input.attachments)
