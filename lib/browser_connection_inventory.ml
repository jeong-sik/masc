module B = Browser_lane
module S = Browser_selection
type issue =
  | Source_unavailable of {instance_id:string; message:string}
  | Source_unreadable of {instance_id:string; message:string}
  | Source_unready of {instance_id:string; message:string}
  | Duplicate_client of {client_id:B.client_id; instances:string list}
let issue_message = function
  | Source_unavailable {instance_id;message} | Source_unreadable {instance_id;message}
  | Source_unready {instance_id;message} -> "Browser worker " ^ instance_id ^ ": " ^ message
  | Duplicate_client {client_id;instances} ->
      "Browser client " ^ B.client_id_to_string client_id ^ " is reported by multiple workers: "
      ^ String.concat ", " instances
let issue_to_json issue =
  let source kind instance_id message = `Assoc ["kind",`String kind;
    "instanceId",`String instance_id;"message",`String message] in
  match issue with
  | Source_unavailable {instance_id;message} -> source "unavailable" instance_id message
  | Source_unreadable {instance_id;message} -> source "unreadable" instance_id message
  | Source_unready {instance_id;message} -> source "unready" instance_id message
  | Duplicate_client {client_id;instances} -> `Assoc ["kind",`String "duplicate_client";
      "clientId",`String (B.client_id_to_string client_id);
      "instances",`List (List.map (fun id -> `String id) instances)]
let issues_to_json issues = `List (List.map issue_to_json issues)
open Result.Syntax
let issue_of_json value =
  let* fields=match value with `Assoc fields -> Ok fields | _ -> Error "inventory issue must be an object" in
  let exact names=if List.sort String.compare (List.map fst fields)=List.sort String.compare names
    then Ok () else Error "invalid or duplicate inventory issue fields" in
  let text key=match List.assoc_opt key fields with
    | Some (`String value) when String.trim value<>"" -> Ok value
    | None|Some _ -> Error ("invalid inventory issue " ^ key) in
  let* kind=text "kind" in
  match kind with
  | "unavailable"|"unreadable"|"unready" ->
      let* ()=exact ["kind";"instanceId";"message"] in
      let* instance_id=text "instanceId" in let* message=text "message" in
      (match kind with
       | "unavailable" -> Ok (Source_unavailable {instance_id;message})
       | "unreadable" -> Ok (Source_unreadable {instance_id;message})
       | "unready" -> Ok (Source_unready {instance_id;message})
       | _ -> Error "unknown inventory issue kind")
  | "duplicate_client" ->
      let* ()=exact ["kind";"clientId";"instances"] in
      let* raw=text "clientId" in let* client_id=B.client_id_of_string raw in
      let* instances=match List.assoc_opt "instances" fields with
        | Some (`List values) ->
          let rec decode acc = function
            | [] -> Ok (List.rev acc)
            | `String value::rest when String.trim value<>"" && not (List.mem value acc) -> decode (value::acc) rest
            | _::_ -> Error "invalid or duplicate inventory issue instances" in
          decode [] values
        | None|Some _ -> Error "invalid inventory issue instances" in
      (match instances with _::_::_ -> Ok (Duplicate_client {client_id;instances})
       | []|[_] -> Error "duplicate client issue requires multiple instances")
  | _ -> Error "unknown inventory issue kind"
let issues_of_json = function
  | `List values ->
      let rec decode acc = function
        | [] -> Ok (List.rev acc)
        | value::rest -> let* issue=issue_of_json value in decode (issue::acc) rest in
      decode [] values
  | _ -> Error "inventory issues must be an array"
type observation = {instance_id:string; published:Browser_addon_observation.published}
type decision = Selected of S.selected | Refused of S.error | Incomplete | Worker_scope_required
type t = {client_rows:Yojson.Safe.t list; issues:issue list; browse:decision; work:decision}
module Client_map = Map.Make (struct type t=B.client_id let compare=compare end)
module Instance_set = Set.Make (String)
let snapshot (published:Browser_addon_observation.published) : S.snapshot =
  {live_activity=B.Enabled;live_clients=published.clients;automation=published.automation;stagehand=published.stagehand}
let decide snapshot verb = match S.choose ~verb ~bound:false ~snapshot S.Automatic with
  | Ok selected -> Selected selected | Error error -> Refused error
let build ~observations ~issues =
  let pairs,issues=List.fold_left (fun (pairs,issues) observation ->
    let rec align acc clients rows = match clients,rows with
      | [],[] -> Some (List.rev acc)
      | (client:B.client_info)::clients,row::rows -> align ((observation.instance_id,client,row)::acc) clients rows
      | [],_::_ | _::_,[] -> None in
    match align [] observation.published.clients observation.published.client_rows with
    | Some rows -> List.rev_append rows pairs,issues
    | None -> pairs,Source_unreadable {instance_id=observation.instance_id;
        message="client metadata and row inventory do not match"}::issues) ([],List.rev issues) observations in
  let pairs=List.rev pairs and issues=List.rev issues in
  let owners=List.fold_left (fun owners (instance_id,(client:B.client_info),_) ->
    Client_map.update client.client_id (function
      | None -> Some (Instance_set.singleton instance_id)
      | Some instances -> Some (Instance_set.add instance_id instances)) owners) Client_map.empty pairs in
  let duplicate_ids=Client_map.filter (fun _ instances -> Instance_set.cardinal instances>1) owners in
  let duplicate_issues=Client_map.bindings duplicate_ids |> List.map (fun (client_id,instances) ->
    Duplicate_client {client_id;instances=Instance_set.elements instances}) in
  let issues=issues @ duplicate_issues in
  let pairs=List.filter (fun (_, (client:B.client_info),_) -> not (Client_map.mem client.client_id duplicate_ids)) pairs in
  let browse,work=match issues,observations with
    | _::_,_ -> Incomplete,Incomplete
    | [],[observation] ->
      let snapshot=snapshot observation.published in
      decide snapshot B.Tabs_list,decide snapshot (B.Session_open {headless=Some false})
    | [],([]|_::_::_) ->
      let disabled:S.work_browser={activity=B.Disabled;registered=false;session=B.Browser_unknown;locate=false} in
      let snapshot:S.snapshot={live_activity=B.Enabled;live_clients=List.map (fun (_,client,_) -> client) pairs;
        automation=disabled;stagehand=disabled} in
      let browse=match decide snapshot B.Tabs_list with
        | Refused S.No_available_browser -> Worker_scope_required
        | Selected _|Refused (Binding_required|Ambiguous_browsers _|Required_actions_unavailable _|Unsupported_required_actions _) as value -> value
        | Incomplete|Worker_scope_required -> Worker_scope_required in
      browse,Worker_scope_required in
  {client_rows=List.map (fun (_,_,row) -> row) pairs;issues;browse;work}
let scoped_refusal message =
  `Assoc ["ok",`Bool false;"error",`Assoc ["code",`String (B.choice_case_code B.Binding_required_case);
    "message",`String message]]
let decision_to_json = function
  | Selected selected -> `Assoc ["ok",`Bool true;"data",S.to_json selected]
  | Refused error -> `Assoc ["ok",`Bool false;"error",S.error_to_json error]
  | Incomplete -> scoped_refusal "Browser worker observations are incomplete. Inspect the inventory issues and choose an observed client explicitly."
  | Worker_scope_required -> scoped_refusal "Choose an observed client explicitly; this inventory does not identify an owned work-session worker. No session was selected or opened."
let to_json t = `Assoc ["clients",`List t.client_rows;"inventoryIssues",issues_to_json t.issues;
  "inventoryComplete",`Bool (t.issues=[]);"automatic",`Assoc ["browse",decision_to_json t.browse;"work",decision_to_json t.work]]
