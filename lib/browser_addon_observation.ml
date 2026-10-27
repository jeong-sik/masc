let ( let* ) = Result.bind

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

type published = {
  clients : Browser_lane.client_info list;
  client_rows : Yojson.Safe.t list;
  automation : Browser_selection.work_browser;
  stagehand : Browser_selection.work_browser;
}

let decode_snapshot = function
  | `Assoc fields ->
      (match List.assoc_opt "state" fields,List.assoc_opt "owned_backends" fields,
         List.assoc_opt "clients" fields with
       | Some (`String "serving"),Some owned,Some (`List rows) ->
           let* automation,stagehand=Browser_addon_inventory.owned_of_json owned in
           let rec decode acc = function
             | [] -> Ok (List.rev acc)
             | `Assoc client::rest ->
                 let* client=Browser_addon_wire.client_of_json (`Assoc (List.remove_assoc "interactions" client)) in
                 if List.exists (fun (known : Browser_lane.client_info) -> known.client_id=client.client_id) acc
                 then Error "duplicate browser inventory client" else decode (client::acc) rest
             | _::_ -> Error "invalid browser inventory client" in
           let* clients=decode [] rows in
           Ok {clients;client_rows=rows;automation;stagehand}
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
let live_backends = List.filter (fun backend ->
  Browser_lane.Backend.lane backend = Browser_lane.Lane_name.Live) Browser_lane.Backend.all
let serves_live backends = List.exists (Lane_addon_types.serves_backend backends) live_backends
(* A client does not say which live source it came from, so a worker that
   serves a live source another worker also serves lists no usable client. *)
let lists_usable_clients ~among backends =
  serves_live backends
  && not (List.exists (fun backend -> Lane_addon_types.serves_backend backends backend
      && List.length (List.filter (fun other -> Lane_addon_types.serves_backend other backend) among) > 1)
      live_backends)
let merge ~among workers =
  let serves backend (backends, _) = Lane_addon_types.serves_backend backends backend in
  let live = List.filter_map (fun (backends, published) ->
    if lists_usable_clients ~among backends then published else None) workers in
  let owned backend pick = match List.filter (serves backend) workers with
    | [ (_, Some published) ] -> pick published
    | [ (_, None) ] | [] | _ :: _ :: _ -> unobserved in
  { clients = List.concat_map (fun published -> published.clients) live;
    client_rows = List.concat_map (fun published -> published.client_rows) live;
    automation = owned Browser_lane.Backend.Automation (fun published -> published.automation);
    stagehand = owned Browser_lane.Backend.Stagehand (fun published -> published.stagehand) }
