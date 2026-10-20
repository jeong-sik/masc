module B = Browser_lane
type t = {selected:Browser_selection.selected;connection_fields:(string * Yojson.Safe.t) list}
let ( let* ) = Result.bind
let selected t=t.selected
let connection_fields t=t.connection_fields
let same_connection left right = left.selected.route=right.selected.route
  && left.connection_fields=right.connection_fields
let of_target selected target = {selected=Browser_selection.bind_target selected target;
  connection_fields=B.target_connection_fields target}
let object_ keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare keys -> Ok fields
  | _ -> Error "invalid or duplicate browser binding fields"
let of_json value =
  let* fields=object_ ["browserSelection";"browserConnection"] value in
  let* choice=object_ ["lane";"clientId";"reason"] (List.assoc "browserSelection" fields) in
  let* reason=match List.assoc "reason" choice with
    | `String raw -> Option.to_result ~none:"unknown browser selection reason" (Browser_selection.reason_of_wire raw)
    | _ -> Error "browser selection reason must be a string" in
  let* route=match List.assoc "lane" choice,List.assoc "clientId" choice with
    | `String "live",`String raw -> B.client_id_of_string raw |> Result.map (fun id -> B.Live_route (Some id))
    | `String "automation",`Null -> Ok B.Automation_route
    | `String "stagehand",`Null -> Ok B.Stagehand_route
    | _ -> Error "browser receipt must name its concrete connection" in
  let keys=match route with B.Live_route _ -> ["clientId";"transport"]
    | Automation_route|Stagehand_route -> ["clientId"] in
  let* connection=object_ keys (List.assoc "browserConnection" fields) in
  let* connection_fields=B.connection_fields_of_json connection in
  let* ()=match route,List.assoc_opt "clientId" connection_fields with
    | B.Live_route (Some id),Some (`String actual) when B.client_id_to_string id=actual -> Ok ()
    | (Automation_route|Stagehand_route),Some `Null -> Ok ()
    | (Live_route _|Automation_route|Stagehand_route),(None|Some _) -> Error "browser selection and connection disagree" in
  Ok {selected={Browser_selection.route;reason};connection_fields}
let to_json t=`Assoc ["browserSelection",Browser_selection.to_json t.selected;
  "browserConnection",`Assoc t.connection_fields]
let annotate t = function
  | `Assoc fields ->
      let protected="source"::"lane"::"browserSelection"::"browserConnection"::B.connection_field_names in
      let lane=B.Lane_name.to_wire (B.route_lane_name t.selected.route) in
      `Assoc (["source",`String lane;"lane",`String lane;
        "browserSelection",Browser_selection.to_json t.selected] @ t.connection_fields
        @ List.filter (fun (key,_) -> not (List.mem key protected)) fields)
  | value -> value
