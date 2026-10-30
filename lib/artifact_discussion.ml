module Engine = Artifact_document_engine
module Index = Map.Make (String)
type command =
  | Comment of { position : Engine.selection; quote : string; body : string; proposal : string option }
  | Reply of { thread_id : string; body : string }
  | Resolve of string | Reopen of string | Accept of string | Reject of string
type request = { id : string; command : command }
type event = { request : request; actor : string; at : string; applied : Engine.selection option }
type message = { id : string; actor : string; at : string; body : string }
type decision = Pending | Applied of event | Rejected of event
type thread = { id : string; position : Engine.selection; quote : string; messages : message list;
  proposal : string option; decision : decision; resolved : bool }
open Result.Syntax
let nonblank text = String.is_valid_utf_8 text && String.trim text <> ""
let uuid value = let* canonical = Random_id.parse_uuid_v7 value in
  if canonical = value then Ok () else Error "noncanonical discussion id"
let fields allowed = function
  | `Assoc values when List.length values = List.length (List.sort_uniq String.compare (List.map fst values))
      && List.for_all (fun (name, _) -> List.mem name allowed) values -> Ok values
  | _ -> Error "duplicate, unknown or non-object discussion fields"
let field name values = Option.value ~default:`Null (List.assoc_opt name values)
let string name values = match field name values with
  | `String value when String.is_valid_utf_8 value -> Ok value | _ -> Error ("invalid discussion " ^ name)
let command_to_json = function
  | Comment { position; quote; body; proposal } -> `Assoc ["kind", `String "comment";
      "position", Engine.selection_to_json position; "quote", `String quote; "body", `String body;
      "proposal", (match proposal with None -> `Null | Some value -> `String value)]
  | Reply { thread_id; body } -> `Assoc ["kind", `String "reply"; "thread_id", `String thread_id; "body", `String body]
  | Resolve id -> `Assoc ["kind", `String "resolve"; "thread_id", `String id]
  | Reopen id -> `Assoc ["kind", `String "reopen"; "thread_id", `String id]
  | Accept id -> `Assoc ["kind", `String "accept"; "thread_id", `String id]
  | Reject id -> `Assoc ["kind", `String "reject"; "thread_id", `String id]
let validate_request (request : request) =
  let* () = uuid request.id in
  match request.command with
  | Comment { position; quote; body; proposal } ->
    let* _ = Engine.selection_of_json (Engine.selection_to_json position) in
    if String.is_valid_utf_8 quote && nonblank body && Option.fold ~none:true ~some:String.is_valid_utf_8 proposal
    then Ok () else Error "comment, quote or proposal is not valid UTF-8 text"
  | Reply { thread_id; body } -> let* () = uuid thread_id in
    if nonblank body then Ok () else Error "reply must be nonblank UTF-8"
  | Resolve id | Reopen id | Accept id | Reject id -> uuid id
let command_of_json json =
  let* all = fields ["kind"; "position"; "quote"; "body"; "proposal"; "thread_id"] json in
  let* kind = string "kind" all in
  match kind with
  | "comment" ->
    let* values = fields ["kind"; "position"; "quote"; "body"; "proposal"] json in
    let* position = Engine.selection_of_json (field "position" values) in
    let* quote = string "quote" values in let* body = string "body" values in
    let* proposal = match List.assoc_opt "proposal" values with
      | None | Some `Null -> Ok None | Some (`String text) when String.is_valid_utf_8 text -> Ok (Some text)
      | _ -> Error "proposal must be null or UTF-8 text" in
    Ok (Comment { position; quote; body; proposal })
  | "reply" ->
    let* values = fields ["kind"; "thread_id"; "body"] json in
    let* thread_id = string "thread_id" values in let* body = string "body" values in Ok (Reply { thread_id; body })
  | "resolve" | "reopen" | "accept" | "reject" ->
    let* values = fields ["kind"; "thread_id"] json in let* id = string "thread_id" values in
    (match kind with "resolve" -> Ok (Resolve id) | "reopen" -> Ok (Reopen id)
      | "accept" -> Ok (Accept id) | "reject" -> Ok (Reject id) | _ -> Error "unknown discussion kind")
  | _ -> Error "unknown discussion kind"
let request_to_json (request : request) = `Assoc ["id", `String request.id; "command", command_to_json request.command]
let request_of_json json =
  let* values = fields ["id"; "command"] json in let* id = string "id" values in
  let* command = command_of_json (field "command" values) in
  let request = { id; command } in let* () = validate_request request in Ok request
type projection = { events : event Index.t; threads : thread Index.t; order : string list }
let thread_id = function
  | Comment _ -> None | Reply { thread_id; _ } -> Some thread_id
  | Resolve id | Reopen id | Accept id | Reject id -> Some id
let eligible projection command = match thread_id command with
  | None -> Ok None
  | Some id -> (match Index.find_opt id projection.threads with
    | None -> Error "discussion thread not found"
    | Some thread -> match command with
      | Accept _ | Reject _ -> (match thread.proposal, thread.decision with
        | Some _, Pending -> Ok (Some thread)
        | None, (Pending | Applied _ | Rejected _) | Some _, (Applied _ | Rejected _) -> Error "proposal is absent or already decided")
      | Comment _ | Reply _ | Resolve _ | Reopen _ -> Ok (Some thread))
let project events =
  List.fold_left (fun result (event : event) ->
    let* projection = result in let* () = validate_request event.request in
    if Index.mem event.request.id projection.events then Error "duplicate discussion request id"
    else if not (nonblank event.actor && nonblank event.at) then Error "invalid discussion author or timestamp"
    else let* existing = eligible projection event.request.command in
    let* () = match event.request.command, event.applied with
      | Accept _, Some position -> Engine.selection_of_json (Engine.selection_to_json position) |> Result.map (fun _ -> ())
      | (Comment _ | Reply _ | Resolve _ | Reopen _ | Reject _), None -> Ok ()
      | Accept _, None | (Comment _ | Reply _ | Resolve _ | Reopen _ | Reject _), Some _ -> Error "discussion effect does not match command" in
    let message body = { id = event.request.id; actor = event.actor; at = event.at; body } in
    let* thread, order = match event.request.command, existing with
      | Comment { position; quote; body; proposal }, None ->
        Ok ({ id = event.request.id; position; quote; messages = [message body]; proposal; decision = Pending; resolved = false }, event.request.id :: projection.order)
      | Reply { body; _ }, Some thread -> Ok ({ thread with messages = message body :: thread.messages }, projection.order)
      | Resolve _, Some thread -> Ok ({ thread with resolved = true }, projection.order)
      | Reopen _, Some thread -> Ok ({ thread with resolved = false }, projection.order)
      | Accept _, Some thread -> Ok ({ thread with decision = Applied event; resolved = true }, projection.order)
      | Reject _, Some thread -> Ok ({ thread with decision = Rejected event; resolved = true }, projection.order)
      | Comment _, Some _ | (Reply _ | Resolve _ | Reopen _ | Accept _ | Reject _), None -> Error "invalid discussion transition" in
    Ok { events = Index.add event.request.id event projection.events; threads = Index.add thread.id thread projection.threads; order })
    (Ok { events = Index.empty; threads = Index.empty; order = [] }) events
let threads events =
  let* projection = project events in
  Ok (List.rev_map (fun id -> let thread = Index.find id projection.threads in
    { thread with messages = List.rev thread.messages }) projection.order)
let check events ~actor (request : request) =
  let* () = validate_request request in
  if not (nonblank actor) then Error "invalid discussion actor"
  else let* projection = project events in
    match Index.find_opt request.id projection.events with
    | Some event when event.actor = actor && event.request = request -> Ok (Some event)
    | Some _ -> Error "discussion request id already belongs to another command or author"
    | None -> let* _ = eligible projection request.command in Ok None
let append events ~actor ~at request ~applied =
  let* previous = check events ~actor request in
  match previous with
  | Some _ -> Ok events
  | None -> let events = events @ [{ request; actor; at; applied }] in let* _ = project events in Ok events
let event_to_json (event : event) = `Assoc ["request", request_to_json event.request; "actor", `String event.actor;
  "at", `String event.at; "applied", (match event.applied with None -> `Null | Some value -> Engine.selection_to_json value)]
let events_to_json events = `List (List.map event_to_json events)
let events_of_json = function
  | `List values ->
    let* events = List.fold_right (fun json result ->
      let* rest = result in let* values = fields ["request"; "actor"; "at"; "applied"] json in
      let* request = request_of_json (field "request" values) in
      let* actor = string "actor" values in let* at = string "at" values in
      let* applied = match List.assoc_opt "applied" values with
        | Some `Null -> Ok None | Some json -> Engine.selection_of_json json |> Result.map Option.some
        | None -> Error "missing discussion effect" in
      Ok ({ request; actor; at; applied } :: rest)) values (Ok []) in
    let* _ = project events in Ok events
  | _ -> Error "expected discussion event list"
let thread_to_json (thread : thread) =
  let decision = match thread.decision with
    | Pending -> `Assoc ["kind", `String "pending"]
    | Applied event -> `Assoc ["kind", `String "applied"; "event", event_to_json event]
    | Rejected event -> `Assoc ["kind", `String "rejected"; "event", event_to_json event] in
  `Assoc ["id", `String thread.id; "position", Engine.selection_to_json thread.position; "quote", `String thread.quote;
    "messages", `List (List.map (fun (message : message) -> `Assoc ["id", `String message.id; "actor", `String message.actor;
      "at", `String message.at; "body", `String message.body]) thread.messages);
    "proposal", (match thread.proposal with None -> `Null | Some value -> `String value);
    "decision", decision; "resolved", `Bool thread.resolved]
