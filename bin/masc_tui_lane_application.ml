type target = {
  source_path : string; installation_id : string; source_revision : string;
  desired_revision : string; enabled : bool;
}
type state = Starting | Cleaning | Applied of string | Inactive
  | Failed of string list | Unknown of string list
type observation = { target : target; state : state }
type tracking = Observed of state | Awaiting_declaration | Different_source
  | Different_inputs | Unavailable of string

let ( let* ) = Result.bind
let field key = function
  | `Assoc fields -> (match List.assoc_opt key fields with
      | Some value -> Ok value | None -> Error ("Missing application field: " ^ key))
  | _ -> Error "Expected application object"
let text = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error "Expected non-blank application text"
let get parse key json = let* value = field key json in parse value
let messages = function
  | `List (_ :: _ as values) ->
      List.fold_right (fun value rest -> let* value = text value in
        let* rest = rest in Ok (value :: rest)) values (Ok [])
  | _ -> Error "Expected application explanations"
let decode json =
  let* source_path = get text "source_path" json in
  let* installation_id = get text "id" json in
  let* source_revision = get text "source_revision" json in
  let* desired_revision = get text "desired_revision" json in
  let* enabled = get (function `Bool enabled -> Ok enabled
    | _ -> Error "Expected application enabled boolean") "enabled" json in
  let* application = field "application" json in
  let* kind = get text "kind" application in
  let* state = match kind with
    | "starting" when enabled -> Ok Starting
    | "cleaning" -> Ok Cleaning
    | "applied" when enabled ->
        let* instance = get text "instance_id" application in Ok (Applied instance)
    | "inactive" when not enabled -> Ok Inactive
    | "failed" -> let* messages = get messages "messages" application in Ok (Failed messages)
    | "unknown" -> let* messages = get messages "messages" application in Ok (Unknown messages)
    | _ -> Error "Unknown or inconsistent declaration application state" in
  Ok {target={source_path;installation_id;source_revision;desired_revision;enabled};state}

let track ~target ~complete observations =
  if not complete then Unavailable "Configuration inventory is incomplete"
  else match List.filter (fun observation ->
    observation.target.source_path = target.source_path
    || observation.target.installation_id = target.installation_id) observations with
  | [] -> Awaiting_declaration
  | [observation] ->
      let observed = observation.target in
      if observed.source_path <> target.source_path
         || observed.installation_id <> target.installation_id
         || observed.source_revision <> target.source_revision
      then Different_source
      else if observed.desired_revision <> target.desired_revision
              || observed.enabled <> target.enabled then Different_inputs
      else Observed observation.state
  | _ :: _ -> Unavailable "Multiple declarations claim this installation or path"

let describe = function
  | Observed Starting -> "Starting · waiting for worker startup"
  | Observed Cleaning -> "Cleaning · waiting for all previous workers"
  | Observed (Applied instance) -> "Applied · worker " ^ instance
  | Observed Inactive -> "Off · worker cleanup confirmed"
  | Observed (Failed messages) -> "Application failed: " ^ String.concat "; " messages
  | Observed (Unknown messages) -> "Application unknown: " ^ String.concat "; " messages
  | Awaiting_declaration -> "Awaiting declaration reconciliation · inspect configuration issues"
  | Different_source -> "Different TOML observed · this revision is not confirmed; l:read current"
  | Different_inputs -> "Worker inputs changed · this revision is not confirmed; l:read current"
  | Unavailable detail -> "Application unknown: " ^ detail

type ticket = { generation : int; identity : unit ref }
type 'a reading = { in_flight : ticket option; received : ('a, string) result option }
let empty = {in_flight=None;received=None}
let start ~generation reading =
  match reading.in_flight with
  | Some ticket when ticket.generation = generation -> None
  | Some _ | None ->
      let ticket = {generation;identity=ref ()} in
      Some ({reading with in_flight=Some ticket}, ticket)
let finish ~generation ticket result reading =
  match reading.in_flight with
  | Some current when current.identity == ticket.identity ->
      if generation = ticket.generation then {in_flight=None;received=Some result}
      else {reading with in_flight=None}
  | Some _ | None -> reading
let accept result = {in_flight=None;received=Some result}
let value reading = reading.received
let pending reading = Option.is_some reading.in_flight
