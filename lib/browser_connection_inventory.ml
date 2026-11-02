module B = Browser_lane
module S = Browser_selection
type issue =
  | Source_unavailable of {instance_id:string; message:string}
  | Source_unreadable of {instance_id:string; message:string}
  | Source_unready of {instance_id:string; message:string}
  | Duplicate_client of {client_id:B.client_id; instances:string list}
  | Duplicate_ego_space of {space_id:int; instances:string list}
  | Ego_user_owned_space of {instance_id:string; space:string; observed_at:float}
let issue_message = function
  | Source_unavailable {instance_id;message} | Source_unreadable {instance_id;message}
  | Source_unready {instance_id;message} -> "Browser worker " ^ instance_id ^ ": " ^ message
  | Duplicate_client {client_id;instances} ->
      "Browser client " ^ B.client_id_to_string client_id ^ " is reported by multiple workers: "
      ^ String.concat ", " instances
  | Duplicate_ego_space {space_id;instances} ->
      Printf.sprintf "Ego Space %d is reported by conflicting browser controllers: %s" space_id (String.concat ", " instances)
  | Ego_user_owned_space {instance_id;space;_} ->
      Printf.sprintf "Browser worker %s: ego task space %S is user-owned, so the live ego lane refuses it; take_over reclaims it after the operator asks to continue"
        instance_id space
let issue_to_json issue =
  let source kind instance_id message = `Assoc ["kind",`String kind;
    "instanceId",`String instance_id;"message",`String message] in
  match issue with
  | Source_unavailable {instance_id;message} -> source "unavailable" instance_id message
  | Source_unreadable {instance_id;message} -> source "unreadable" instance_id message
  | Source_unready {instance_id;message} -> source "unready" instance_id message
  | Ego_user_owned_space {instance_id;space;observed_at} -> `Assoc ["kind",`String "ego_user_owned_space";
    "instanceId",`String instance_id;"space",`String space;"observedAt",`Float observed_at]
  | Duplicate_client {client_id;instances} -> `Assoc ["kind",`String "duplicate_client";
      "clientId",`String (B.client_id_to_string client_id);
      "instances",`List (List.map (fun id -> `String id) instances)]
  | Duplicate_ego_space {space_id;instances} -> `Assoc ["kind",`String "duplicate_ego_space";
      "spaceId",`Int space_id;"instances",`List (List.map (fun id -> `String id) instances)]
let issues_to_json issues = `List (List.map issue_to_json issues)
open Result.Syntax
let issue_of_json value =
  let* fields=match value with `Assoc fields -> Ok fields | _ -> Error "inventory issue must be an object" in
  let exact names=if List.sort String.compare (List.map fst fields)=List.sort String.compare names
    then Ok () else Error "invalid or duplicate inventory issue fields" in
  let text key=match List.assoc_opt key fields with
    | Some (`String value) when String.trim value<>"" -> Ok value
    | None|Some _ -> Error ("invalid inventory issue " ^ key) in
  let instances ()=match List.assoc_opt "instances" fields with
    | Some (`List values) ->
      let rec decode acc = function
        | [] -> Ok (List.rev acc)
        | `String value::rest when String.trim value<>"" && not (List.mem value acc) -> decode (value::acc) rest
        | _::_ -> Error "invalid or duplicate inventory issue instances" in
      decode [] values
    | None|Some _ -> Error "invalid inventory issue instances" in
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
      let* instances=instances () in
      (match instances with _::_::_ -> Ok (Duplicate_client {client_id;instances})
       | []|[_] -> Error "duplicate client issue requires multiple instances")
  | "duplicate_ego_space" ->
      let* ()=exact ["kind";"spaceId";"instances"] in
      let* space_id=match List.assoc_opt "spaceId" fields with
        | Some (`Int id) ->
            Browser_configuration.validate_ego_space (Browser_configuration.Existing_space id) |> Result.map (fun () -> id)
        | None|Some _ -> Error "invalid inventory issue Space ID" in
      let* instances=instances () in
      (match instances with _::_ -> Ok (Duplicate_ego_space {space_id;instances})
       | [] -> Error "duplicate Space issue requires controller instances")
  | "ego_user_owned_space" ->
      let* ()=exact ["kind";"instanceId";"space";"observedAt"] in
      let* instance_id=text "instanceId" in
      let* space=text "space" in
      let* observed_at=match List.assoc_opt "observedAt" fields with
        | Some (`Float value) when Float.is_finite value && value >= 0. -> Ok value
        | None|Some _ -> Error "invalid inventory issue observation time" in
      Ok (Ego_user_owned_space {instance_id;space;observed_at})
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
module Instance_set = Set.Make (String)
let snapshot (published:Browser_addon_observation.published) : S.snapshot =
  {live_activity=B.Enabled;live_clients=published.clients;live_space_presence=published.space_presence;automation=published.automation;stagehand=published.stagehand}
let decide snapshot verb = match S.choose ~verb ~bound:false ~snapshot S.Automatic with
  | Ok selected -> Selected selected | Error error -> Refused error
let breaks_completeness (issue : issue)=match issue with
  | Ego_user_owned_space _ -> false
  | Source_unavailable _|Source_unreadable _|Source_unready _|Duplicate_client _|Duplicate_ego_space _ -> true
let build ~observations ~issues =
  let ego_issues=List.concat_map (fun observation ->
    List.map (fun (unavailable:Browser_addon_observation.unavailable) ->
      match unavailable with
      | Browser_addon_observation.Ego_user_owned_name {space;observed_at} ->
        Ego_user_owned_space {instance_id=observation.instance_id;space;observed_at})
      observation.published.unavailable) observations in
  let pairs,issues=List.fold_left (fun (pairs,issues) observation ->
    let rec align acc clients rows = match clients,rows with
      | [],[] -> Some (List.rev acc)
      | (client:B.client_info)::clients,row::rows -> align ((observation.instance_id,client,row)::acc) clients rows
      | [],_::_ | _::_,[] -> None in
    match align [] observation.published.clients observation.published.client_rows with
    | Some rows -> List.rev_append rows pairs,issues
    | None -> pairs,Source_unreadable {instance_id=observation.instance_id;
        message="client metadata and row inventory do not match"}::issues) ([],List.rev (ego_issues @ issues)) observations in
  let pairs=List.rev pairs and issues=List.rev issues in
  let conflicts=Browser_addon_observation.live_conflicts (List.map (fun (_,client,_) -> client) pairs) in
  let duplicate_issues=List.map (fun conflict ->
    let instances=List.fold_left (fun owners (instance_id,client,_) ->
      if Browser_addon_observation.conflicts_with client conflict then Instance_set.add instance_id owners else owners)
      Instance_set.empty pairs |> Instance_set.elements in
    match conflict with
    | Browser_addon_observation.Duplicate_client client_id -> Duplicate_client {client_id;instances}
    | Duplicate_ego_space space_id -> Duplicate_ego_space {space_id;instances}) conflicts in
  let issues=issues @ duplicate_issues in
  let pairs=List.filter (fun (_,client,_) -> not (List.exists (Browser_addon_observation.conflicts_with client) conflicts)) pairs in
  (* A refused ego Space is a lane fact the worker answered completely, not
     a missing observation: it stays listed as an issue but does not make
     the inventory incomplete, so a healthy client of another transport on
     the same worker is still chosen automatically. *)
  let incomplete=List.exists breaks_completeness issues in
  let browse,work=match incomplete,observations with
    | true,_ -> Incomplete,Incomplete
    | false,[observation] ->
      let snapshot=snapshot observation.published in
      decide snapshot B.Tabs_list,decide snapshot (B.Session_open {headless=Some false})
    | false,([]|_::_::_) ->
      let disabled:S.work_browser={activity=B.Disabled;registered=false;session=B.Browser_unknown;locate=false} in
      let snapshot:S.snapshot={live_activity=B.Enabled;live_clients=List.map (fun (_,client,_) -> client) pairs;
        live_space_presence=List.concat_map (fun observation -> observation.published.space_presence) observations;
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
let to_json t =
  `Assoc ["clients",`List t.client_rows;"inventoryIssues",issues_to_json t.issues;
  "inventoryComplete",`Bool (not (List.exists breaks_completeness t.issues));
  "automatic",`Assoc ["browse",decision_to_json t.browse;"work",decision_to_json t.work]]
