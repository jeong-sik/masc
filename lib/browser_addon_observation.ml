open Result.Syntax

type unavailable = Ego_user_owned_name of { space : string; observed_at : float }
let unavailable_to_json = function
  | Ego_user_owned_name {space; observed_at} -> `Assoc ["backend",`String "ego";
      "reason",`String "user_owned_name";"space",`String space;
      "observedAt",`Float observed_at;"recheck",`String "worker_restart"]

let unavailable_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "backend" fields, List.assoc_opt "reason" fields,
           List.assoc_opt "space" fields, List.assoc_opt "observedAt" fields, List.assoc_opt "recheck" fields with
     | Some (`String "ego"), Some (`String "user_owned_name"), Some (`String space),
       Some (`Float observed_at), Some (`String "worker_restart")
       when space <> "" && Float.is_finite observed_at && observed_at >= 0. ->
       Ok (Ego_user_owned_name {space; observed_at})
     | _ -> Error "invalid unavailable browser backend")
  | _ -> Error "invalid unavailable browser backend"

let of_snapshot ~observed_at = function
  | `Assoc fields ->
      let output={Lane_addon_types.rows=[{
      id="browser";lane_id="browser/connections";kind=Value;
      title="Browser worker";observed_at;subject_id="browser";
      clock=None;actor=None;fields;evidence=[];related_ids=[]}];coverage=[]} in
      (* Keep the same row checks as MCP observation decoding, including
         duplicate fields and finite observation time, before publication. *)
      Lane_addon_types.output_of_json (Lane_addon_types.output_to_json output)
  | _ -> Error "browser snapshot must be an object"

let publish_client (client : Browser_lane.client_info) ~(space_observation : Browser_ego_space_observation.t option) =
  let observation=match client.transport,client.space,space_observation with
    | Ego_task_space,Some space,Some observation when space.id=observation.space.id ->
        Browser_ego_space_observation.to_json observation
    | (Ego_task_space|Web_extension|Webdriver_bidi),(Some _|None),(Some _|None) -> `Null in
  let `Assoc fields=Browser_lane.client_json client in
  `Assoc (("spaceObservation",observation)::fields)

type published = {
  clients : Browser_lane.client_info list;
  client_rows : Yojson.Safe.t list;
  automation : Browser_selection.work_browser;
  stagehand : Browser_selection.work_browser;
  unavailable : unavailable list;
}

let decode_snapshot = function
  | `Assoc fields ->
      (match List.assoc_opt "state" fields,List.assoc_opt "owned_backends" fields,
         List.assoc_opt "clients" fields with
       | Some (`String "serving"),Some owned,Some (`List rows) ->
           let* automation,stagehand=Browser_addon_inventory.owned_of_json owned in
           let rec decode acc = function
             | [] -> Ok (List.rev acc)
             | `Assoc row::rest ->
                 let* ()=if List.sort String.compare (List.map fst row)
                   =["browser";"clientId";"engineVersion";"interactions";"lastActivities";"space";"spaceObservation";"transport";"version"]
                   then Ok () else Error "invalid browser inventory client fields" in
                 let validate name decode = match List.assoc_opt name row with
                   | Some (`List values) -> List.fold_left (fun result value ->
                       let* ()=result in Result.map (fun _ -> ()) (decode value)) (Ok ()) values
                   | None|Some _ -> Error ("invalid browser " ^ name) in
                 let* ()=validate "interactions" Browser_lane.interaction_activity_of_json in
                 let* ()=validate "lastActivities" Browser_lane.settled_activity_of_json in
                 let* client=Browser_addon_wire.client_of_json (`Assoc
                   (List.filter (fun (name,_) -> name<>"interactions" && name<>"lastActivities" && name<>"spaceObservation") row)) in
                 let* ()=match client.transport,client.space,List.assoc_opt "spaceObservation" row with
                   | Ego_task_space,Some space,Some value when value<>`Null ->
                       Browser_ego_space_observation.of_json ~expected_id:space.id value |> Result.map (fun _ -> ())
                   | (Ego_task_space|Web_extension|Webdriver_bidi),(Some _|None),Some `Null -> Ok ()
                   | (Ego_task_space|Web_extension|Webdriver_bidi),(Some _|None),(None|Some _) ->
                       Error "invalid browser Space observation" in
                 if List.exists (fun (known : Browser_lane.client_info) -> known.client_id=client.client_id) acc
                 then Error "duplicate browser inventory client" else decode (client::acc) rest
             | _::_ -> Error "invalid browser inventory client" in
           let* clients=decode [] rows in
           let rec unavailable acc = function
             | [] -> Ok (List.rev acc)
             | row :: rest -> let* item = unavailable_of_json row in unavailable (item :: acc) rest in
           let* unavailable = match List.assoc_opt "unavailable" fields with
             | None -> Ok []
             | Some (`List rows) -> unavailable [] rows
             | Some _ -> Error "invalid unavailable browser backends" in
           Ok {clients;client_rows=rows;automation;stagehand;unavailable}
       | Some (`String "retired"),(None|Some _),(None|Some _) -> Error "the browser worker is retired"
       | (None|Some _),(None|Some _),(None|Some _) -> Error "browser inventory is unavailable")
  | _ -> Error "browser inventory is unavailable"

(* The runtime stores an observation with every row id and lane id prefixed
   by its instance and sequence (Lane_addon_runtime.namespace), so the one row
   [of_snapshot] wrote is found by its shape, not by its id. *)
let read (output : Lane_addon_types.output) = match output.rows with
  | [ row ] -> decode_snapshot (`Assoc row.fields)
  | [] | _::_::_ -> Error "the browser observation does not hold exactly the browser worker row"

let unobserved : Browser_selection.work_browser =
  {activity=Browser_lane.Unobserved;registered=false;session=Browser_lane.Browser_unknown;locate=false}
let serves_live backend = Browser_lane.Backend.lane backend = Browser_lane.Lane_name.Live
(* What a worker publishes does not say which worker of its source it came
   from, so when two workers serve one source neither answers for its lane. *)
let answers_for ~among lane backend =
  Browser_lane.Backend.lane backend = lane
  && List.length (List.filter (fun other -> other = backend) among) < 2
let lists_usable_clients ~among backend = answers_for ~among Browser_lane.Lane_name.Live backend
let merge ~among workers =
  let live = List.filter_map (fun (backend, published) ->
    if lists_usable_clients ~among backend then published else None) workers in
  let owned source pick = match List.filter (fun (backend, _) -> backend = source) workers with
    | [ (_, Some published) ] -> pick published
    | [ (_, None) ] | [] | _ :: _ :: _ -> unobserved in
  { clients = List.concat_map (fun published -> published.clients) live;
    client_rows = List.concat_map (fun published -> published.client_rows) live;
    unavailable = List.concat_map (fun published -> published.unavailable) live;
    automation = owned Browser_lane.Backend.Automation (fun published -> published.automation);
    stagehand = owned Browser_lane.Backend.Stagehand (fun published -> published.stagehand) }
