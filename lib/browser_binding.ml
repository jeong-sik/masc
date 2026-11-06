module B = Browser_lane
type t = {selected:Browser_selection.selected;connection_fields:(string * Yojson.Safe.t) list;
  backend:Browser_capabilities.backend;space:B.ego_space option}
let selected t=t.selected
let connection_fields t=t.connection_fields
let backend t=t.backend
let same_connection left right = left.selected.route=right.selected.route
  && left.backend=right.backend && B.same_space_id left.space right.space
let of_browser selected browser = {selected=Browser_selection.bind selected browser;
  connection_fields=(match browser with
    | Browser_selection.Connected info -> B.live_connection_fields ~client_id:info.client_id ~transport:info.transport ~space:info.space);
  space=(match browser with Browser_selection.Connected info -> info.space);
  backend=Browser_selection.backend_of_browser browser}
(* A lane-level command the lane answers without a client: the live lane
   itself is the browser, and the transport it reports is the ego task
   space lane it serves. *)
let of_lane selected =
  {selected;connection_fields=[B.client_id_field,`Null];
   backend=Browser_capabilities.Connected B.Ego_task_space;space=None}
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
