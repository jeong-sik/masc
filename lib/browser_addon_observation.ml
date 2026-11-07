open Result.Syntax

type unavailable =
  | Ego_user_owned_name of { space : string; ids : int list; observed_at : float }
  | Ego_space_missing of { space : string; space_id : int; observed_at : float }
let unavailable_to_json = function
  | Ego_user_owned_name {space; ids; observed_at} -> `Assoc ["backend",`String "ego";
      "reason",`String "user_owned_name";"space",`String space;
      "ids",`List (List.map (fun id -> `Int id) ids);
      "observedAt",`Float observed_at;"recheck",`String "take_over"]
  | Ego_space_missing {space; space_id; observed_at} -> `Assoc ["backend",`String "ego";
      "reason",`String "space_missing";"space",`String space;"spaceId",`Int space_id;
      "observedAt",`Float observed_at;"recheck",`String "take_over"]

let unavailable_of_json = function
  | `Assoc fields ->
    (* A JSON number may arrive without its decimal point; both spell a
       wall-clock second. *)
    let seconds = function
      | Some (`Float value) -> Some value
      | Some (`Int value) -> Some (Float.of_int value)
      | Some _|None -> None in
    let invalid = Error "invalid unavailable browser backend" in
    (match List.assoc_opt "backend" fields, List.assoc_opt "reason" fields,
           List.assoc_opt "space" fields, seconds (List.assoc_opt "observedAt" fields),
           List.assoc_opt "recheck" fields with
     | Some (`String "ego"), Some (`String reason), Some (`String space), Some observed_at,
       Some (`String "take_over") when space <> "" && Float.is_finite observed_at && observed_at >= 0. ->
       (match reason, List.assoc_opt "ids" fields, List.assoc_opt "spaceId" fields with
        | "user_owned_name", Some (`List rows), None ->
          let rec ids acc = function
            | [] -> Ok (List.rev acc)
            | `Int id :: rest when id > 0 && not (List.mem id acc) -> ids (id :: acc) rest
            | _ :: _ -> invalid in
          ids [] rows |> Result.map (fun ids -> Ego_user_owned_name {space; ids; observed_at})
        | "space_missing", None, Some (`Int space_id) when space_id > 0 ->
          Ok (Ego_space_missing {space; space_id; observed_at})
        | _, _, _ -> invalid)
     | _ -> invalid)
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

let publish_client (client : Browser_lane.client_info) ~(space_observation : Browser_ego_space_observation.t option)
    ~(space_presence : Browser_ego_space_observation.presence option) =
  let observation=match client.transport,client.space,space_observation with
    | Ego_task_space,Some space,Some observation when space.id=observation.space.id ->
        Browser_ego_space_observation.to_json observation
    | Ego_task_space,(Some _|None),(Some _|None) -> `Null in
  let presence=match client.transport,client.space,space_presence with
    | Ego_task_space,Some space,Some presence when space.id=presence.space_id ->
      Browser_ego_space_observation.presence_to_json presence
    | Ego_task_space,(Some _|None),(Some _|None) -> `Null in
  let `Assoc fields=Browser_lane.client_json client in
  `Assoc (("spacePresence",presence)::("spaceObservation",observation)::fields)

type published = {
  clients : Browser_lane.client_info list;
  space_presence : (Browser_lane.client_id * Browser_ego_space_observation.presence) list;
  client_rows : Yojson.Safe.t list;
  unavailable : unavailable list;
}

let decode_snapshot = function
  | `Assoc fields ->
      (match List.assoc_opt "state" fields,List.assoc_opt "clients" fields with
       | Some (`String "serving"),Some (`List rows) ->
           let rec decode acc = function
             | [] -> Ok (List.rev acc)
             | `Assoc row::rest ->
                 let* ()=if List.sort String.compare (List.map fst row)
                   =["browser";"clientId";"engineVersion";"interactions";"lastActivities";"space";"spaceObservation";"spacePresence";"transport";"version"]
                   then Ok () else Error "invalid browser inventory client fields" in
                 let validate name decode = match List.assoc_opt name row with
                   | Some (`List values) -> List.fold_left (fun result value ->
                       let* ()=result in Result.map (fun _ -> ()) (decode value)) (Ok ()) values
                   | None|Some _ -> Error ("invalid browser " ^ name) in
                 let* ()=validate "interactions" Browser_lane.interaction_activity_of_json in
                 let* ()=validate "lastActivities" Browser_lane.settled_activity_of_json in
                 let* client=Browser_addon_wire.client_of_json (`Assoc
                   (List.filter (fun (name,_) -> name<>"interactions" && name<>"lastActivities" && name<>"spaceObservation" && name<>"spacePresence") row)) in
                 let* ()=match client.transport,client.space,List.assoc_opt "spaceObservation" row with
                   | Ego_task_space,Some space,Some value when value<>`Null ->
                       Browser_ego_space_observation.of_json ~expected_id:space.id value |> Result.map (fun _ -> ())
                   | Ego_task_space,(Some _|None),Some `Null -> Ok ()
                   | Ego_task_space,(Some _|None),(None|Some _) ->
                       Error "invalid browser Space observation" in
                 if List.exists (fun (known : Browser_lane.client_info) -> known.client_id=client.client_id) acc
                 then Error "duplicate browser inventory client" else decode (client::acc) rest
             | _::_ -> Error "invalid browser inventory client" in
           let* clients=decode [] rows in
           let rec presences acc clients rows = match clients,rows with
             | [],[] -> Ok (List.rev acc)
             | (client:Browser_lane.client_info)::clients,`Assoc row::rows ->
               let* presence=match client.transport,client.space,List.assoc_opt "spacePresence" row with
                 | Ego_task_space,Some space,Some value when value<>`Null ->
                   Browser_ego_space_observation.presence_of_json ~expected_id:space.id value
                   |> Result.map (fun presence -> Some (client.client_id,presence))
                 | Ego_task_space,(Some _|None),Some `Null -> Ok None
                 | Ego_task_space,(Some _|None),(None|Some _) ->
                   Error "invalid browser Space presence" in
               presences (match presence with None -> acc | Some value -> value::acc) clients rows
             | [],_::_ | _::_,([]|_::_) -> Error "invalid browser inventory presence alignment" in
           let* space_presence=presences [] clients rows in
           let rec unavailable acc = function
             | [] -> Ok (List.rev acc)
             | row :: rest -> let* item = unavailable_of_json row in unavailable (item :: acc) rest in
           let* unavailable = match List.assoc_opt "unavailable" fields with
             | None -> Ok []
             | Some (`List rows) -> unavailable [] rows
             | Some _ -> Error "invalid unavailable browser backends" in
           Ok {clients;space_presence;client_rows=rows;unavailable}
       | Some (`String "retired"),(None|Some _) -> Error "the browser worker is retired"
       | (None|Some _),(None|Some _) -> Error "browser inventory is unavailable")
  | _ -> Error "browser inventory is unavailable"

(* The runtime stores an observation with every row id and lane id prefixed
   by its instance and sequence (Lane_addon_runtime.namespace), so the one row
   [of_snapshot] wrote is found by its shape, not by its id. *)
let read (output : Lane_addon_types.output) = match output.rows with
  | [ row ] -> decode_snapshot (`Assoc row.fields)
  | [] | _::_::_ -> Error "the browser observation does not hold exactly the browser worker row"

let serves_live backend = Browser_lane.Backend.lane backend = Browser_lane.Lane_name.Live
type live_conflict = Duplicate_client of Browser_lane.client_id | Duplicate_ego_space of int
module Client_map = Map.Make (struct type t=Browser_lane.client_id let compare=compare end)
module Space_map = Map.Make (Int)
let ego_space_id (client:Browser_lane.client_info) = match client.transport,client.space with
  | Browser_lane.Ego_task_space,Some space -> Some space.id
  | Ego_task_space,None -> None
let live_conflicts clients =
  let duplicate = function None -> Some false | Some _ -> Some true in
  let client_counts,space_counts=List.fold_left (fun (client_counts,space_counts) (client:Browser_lane.client_info) ->
    let client_counts=Client_map.update client.client_id duplicate client_counts in
    let space_counts=match ego_space_id client with None -> space_counts
      | Some id -> Space_map.update id duplicate space_counts in
    client_counts,space_counts) (Client_map.empty,Space_map.empty) clients in
  (Client_map.bindings client_counts |> List.filter_map (fun (id,duplicate) ->
    if duplicate then Some (Duplicate_client id) else None)) @
  (Space_map.bindings space_counts |> List.filter_map (fun (id,duplicate) ->
    if duplicate then Some (Duplicate_ego_space id) else None))
let conflicts_with (client:Browser_lane.client_info) = function
  | Duplicate_client id -> client.client_id=id
  | Duplicate_ego_space id -> ego_space_id client=Some id
let conflict_message = function
  | Duplicate_client id -> "Browser client " ^ Browser_lane.client_id_to_string id ^ " is advertised by multiple browser controllers"
  | Duplicate_ego_space id -> Printf.sprintf "Ego Space %d is advertised by multiple browser controllers; no input was dispatched" id
type client_observation = Observed_clients of Browser_lane.client_info list | Unobserved_clients
type ego_identity_knowledge = Known_ego_identities | Unknown_ego_identities
let ego_identity_knowledge observations =
  if List.exists (function
    | backend,Unobserved_clients -> serves_live backend
    | _,Observed_clients _ -> false) observations
  then Unknown_ego_identities else Known_ego_identities
let check_ego_identity knowledge (client:Browser_lane.client_info) =
  match knowledge,client.transport with
  | Unknown_ego_identities,Browser_lane.Ego_task_space ->
      Error "live browser controller identities are incomplete; the Ego Space may have another controller, so no browser command was dispatched"
  | Known_ego_identities,Ego_task_space -> Ok ()
let merge workers =
  let live=List.filter_map (fun (backend,published) -> if serves_live backend then published else None) workers in
  let clients=List.concat_map (fun published -> published.clients) live in
  let conflicts=live_conflicts clients in
  let usable client=not (List.exists (conflicts_with client) conflicts) in
  let clients=List.filter usable clients in
  let has_id id=List.exists (fun (client:Browser_lane.client_info) -> client.client_id=id) clients in
  let rows published =
    let rec align acc clients rows = match clients,rows with
      | [],[] -> List.rev acc
      | client::clients,row::rows -> align (if usable client then row::acc else acc) clients rows
      | [],_::_ | _::_,[] -> [] in
    align [] published.clients published.client_rows in
  { clients;
    space_presence=List.concat_map (fun published -> List.filter (fun (id,_) -> has_id id) published.space_presence) live;
    client_rows=List.concat_map rows live;
    unavailable=List.concat_map (fun published -> published.unavailable) live }
