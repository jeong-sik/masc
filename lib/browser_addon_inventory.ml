module B = Browser_lane
open Result.Syntax
let activity_to_json = function
  | B.Enabled -> `String "enabled" | Disabled -> `String "disabled" | Unobserved -> `String "unobserved"
let session_to_json = function
  | B.Browser_closed -> `String "closed" | Browser_open -> `String "open"
  | Browser_changing -> `String "changing" | Browser_unknown -> `String "unknown"
let work_to_json (work:Browser_selection.work_browser) = `Assoc [
  "activity",activity_to_json work.activity;"registered",`Bool work.registered;
  "session",session_to_json work.session;"locate",`Bool work.locate]
let observe () : Browser_selection.snapshot =
  let work lane : Browser_selection.work_browser =
    let observed = B.inventory_observation (B.server_lane_name lane) in
    let registered = match observed.backend with B.Executor_registered value -> value | B.Live_clients _ -> false in
    let locate=match lane with B.Server_automation -> B.automation_locate_available ()
      | B.Server_stagehand -> B.stagehand_models_available () in
    {activity=observed.activity;registered;session=B.server_session_observation lane;locate} in
  {live_activity=B.activity B.Lane_name.Live;live_clients=B.connected_clients ();
   automation=work B.Server_automation;stagehand=work B.Server_stagehand}
let owned_to_json (snapshot:Browser_selection.snapshot) = `Assoc [
  "automation",work_to_json snapshot.automation;"stagehand",work_to_json snapshot.stagehand]
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=expected -> Ok fields
  | _ -> Error "invalid owned browser inventory fields"
let work_of_json value =
  let* fields=fields ["activity";"locate";"registered";"session"] value in
  let* activity=match List.assoc_opt "activity" fields with
    | Some (`String "enabled") -> Ok B.Enabled | Some (`String "disabled") -> Ok B.Disabled
    | Some (`String "unobserved") -> Ok B.Unobserved | None|Some _ -> Error "invalid browser activity" in
  let* registered=match List.assoc_opt "registered" fields with
    | Some (`Bool value) -> Ok value | None|Some _ -> Error "invalid browser registration" in
  let* session=match List.assoc_opt "session" fields with
    | Some (`String "closed") -> Ok B.Browser_closed | Some (`String "open") -> Ok B.Browser_open
    | Some (`String "changing") -> Ok B.Browser_changing | Some (`String "unknown") -> Ok B.Browser_unknown
    | None|Some _ -> Error "invalid browser session observation" in
  let* locate=match List.assoc_opt "locate" fields with
    | Some (`Bool value) -> Ok value | None|Some _ -> Error "invalid browser locate availability" in
  Ok {Browser_selection.activity;registered;session;locate}
let owned_of_json value =
  let* fields=fields ["automation";"stagehand"] value in
  let read key = let* value=Option.to_result ~none:"missing owned browser inventory" (List.assoc_opt key fields) in
    work_of_json value in
  let* automation=read "automation" in
  let* stagehand=read "stagehand" in
  Ok (automation,stagehand)
