type t = {
  goal_id : string;
  addon_instance_id : string;
  space : Browser_lane.ego_space;
  actor : string;
}
type error = Invalid of string | Unavailable of string | Conflict of string
  | Goal_reference of Goal_store.goal_reference_error
let error_message = function
  | Invalid detail | Unavailable detail | Conflict detail -> detail
  | Goal_reference (Goal_store.Goal_source_unavailable error) -> Goal_store.unavailable_to_string error
  | Goal_reference (Goal_lock_failed error) -> Masc_domain.masc_error_to_string error
  | Goal_reference (Goal_missing id) -> "Goal does not exist: " ^ id
open Result.Syntax
let path config = Filename.concat (Workspace.masc_dir config) "browser_goal_spaces.json"
let to_json binding = `Assoc ["goalId",`String binding.goal_id;
  "addonInstanceId",`String binding.addon_instance_id;
  "space",Browser_lane.ego_space_to_json binding.space;"actor",`String binding.actor]
let fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error (Invalid "unknown, missing or duplicate Goal Space binding fields")
let text name fields = match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | None | Some _ -> Error (Invalid (name ^ " must be nonblank text"))
let binding_of_json json =
  let* fields = fields ["goalId";"addonInstanceId";"space";"actor"] json in
  let* goal_id = text "goalId" fields in
  let* addon_instance_id = text "addonInstanceId" fields in
  let* actor = text "actor" fields in
  let* space = match List.assoc_opt "space" fields with
    | Some value -> Browser_lane.ego_space_of_json value |> Result.map_error (fun e -> Invalid e)
    | None -> Error (Invalid "space is required") in
  Ok {goal_id;addon_instance_id;space;actor}
let same_space a b = a.addon_instance_id = b.addon_instance_id && a.space.id = b.space.id
let decode json =
  let* fields = fields ["bindings"] json in
  match List.assoc_opt "bindings" fields with
  | Some (`List values) ->
    let rec collect seen = function
      | [] -> Ok (List.rev seen)
      | value :: rest ->
        let* binding = binding_of_json value in
        if List.exists (fun previous -> previous.goal_id = binding.goal_id || same_space previous binding) seen
        then Error (Invalid "duplicate Goal or Ego Space in binding store")
        else collect (binding :: seen) rest in
    collect [] values
  | None | Some _ -> Error (Invalid "bindings must be an array")
let read config =
  match Workspace.read_json_doc config (path config) with
  | Ok None -> Ok []
  | Ok (Some json) -> decode json
  | Error error -> Error (Unavailable (Workspace.json_doc_error_to_string error))
let with_goal config ~goal_id f =
  if String.trim goal_id = "" then Error (Invalid "goalId must be nonblank text") else
  match Goal_store.with_existing_goals config ~goal_ids:[goal_id] f with
  | Ok result -> result
  | Error error -> Error (Goal_reference error)
let find config ~goal_id = with_goal config ~goal_id (fun () ->
  let* bindings = read config in
  Ok (List.find_opt (fun binding -> binding.goal_id = goal_id) bindings))
type commit = { binding : t; created : bool; mirror_error : string option }
let bind config ~goal_id ~addon_instance_id ~space ~actor =
  let* binding = binding_of_json (to_json {goal_id;addon_instance_id;space;actor}) in
  with_goal config ~goal_id (fun () ->
    match Workspace.with_file_lock_r config (path config) (fun () ->
      let* bindings = read config in
      match List.find_opt (fun existing -> existing.goal_id = goal_id) bindings with
      | Some existing when same_space existing binding ->
          Ok {binding=existing;created=false;mirror_error=None}
      | Some _ -> Error (Conflict "Goal already has a different Ego Space binding; no reassignment was made")
      | None ->
        if List.exists (same_space binding) bindings then
          Error (Conflict "Ego Space is already bound to another Goal; no assignment was made")
        else
          let* committed = Workspace.write_json_commit_result config (path config)
            (`Assoc ["bindings",`List (List.map to_json (bindings @ [binding]))])
            |> Result.map_error (fun error -> Unavailable error) in
          Ok {binding;created=true;mirror_error=committed.mirror_error}) with
    | Ok result -> result
    | Error error -> Error (Unavailable (Masc_domain.masc_error_to_string error)))
type unbinding = { removed : t option; mirror_error : string option }
let unbind config ~goal_id =
  with_goal config ~goal_id (fun () ->
    match Workspace.with_file_lock_r config (path config) (fun () ->
      let* bindings = read config in
      match List.partition (fun binding -> binding.goal_id = goal_id) bindings with
      | [], _ -> Ok {removed=None;mirror_error=None}
      | [existing], rest ->
        let* committed = Workspace.write_json_commit_result config (path config)
          (`Assoc ["bindings",`List (List.map to_json rest)])
          |> Result.map_error (fun error -> Unavailable error) in
        Ok {removed=Some existing;mirror_error=committed.mirror_error}
      | _ :: _ :: _, _ -> Error (Invalid "duplicate Goal in binding store")) with
    | Ok result -> result
    | Error error -> Error (Unavailable (Masc_domain.masc_error_to_string error)))
let resolve binding ~addon_instance_id clients =
  if addon_instance_id <> binding.addon_instance_id then
    Error (Conflict "Goal Space belongs to a different browser Add-on; no browser command was dispatched")
  else match List.filter (fun (client:Browser_lane.client_info) ->
    match client.transport,client.space with
    | Browser_lane.Ego_task_space,Some space -> space.id = binding.space.id
    | Ego_task_space,None | (Web_extension|Webdriver_bidi),(None|Some _) -> false) clients with
  | [client] -> Ok client.client_id
  | [] -> Error (Unavailable "Goal's Ego Space is not connected; resume its numeric Space ID before continuing")
  | _::_::_ -> Error (Conflict "multiple connections advertise the Goal's Ego Space; select an explicit browser")
