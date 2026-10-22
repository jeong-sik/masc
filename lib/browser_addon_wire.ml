module B = Browser_lane
let ( let* ) = Result.bind
let string value = `String value
let nullable f = Option.fold ~none:`Null ~some:f
let exact expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> Error ("expected exactly: " ^ String.concat ", " expected)
let required fields key = Option.to_result ~none:("missing " ^ key) (List.assoc_opt key fields)
let text = function `String value when String.trim value<>"" -> Ok value | _ -> Error "expected nonblank text"
let text_field fields key = let* value = required fields key in text value
let boolean = function `Bool value -> Ok value | _ -> Error "expected boolean"
let number = function `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (float_of_int value) | _ -> Error "expected finite number"
let positive value = let* value = number value in
  if value>0. then Ok value else Error "expected positive duration"
let integer = function
  | `Int value when Int64.abs (Int64.of_int value)<=9007199254740991L -> Ok value
  | _ -> Error "expected JavaScript-safe integer"
let tab value = let* value = integer value in if value>=0 then Ok value else Error "expected nonnegative tab ID"
let optional parse = function `Null -> Ok None | value -> parse value |> Result.map Option.some
let optional_field fields key parse = match List.assoc_opt key fields with None -> Ok None | Some value -> parse value |> Result.map Option.some
let optional_tab fields = optional_field fields "tabId" tab
let object_fields allowed = function
  | `Assoc fields when List.for_all (fun (name,_) -> List.mem name allowed) fields
      && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
  | _ -> Error "unknown or duplicate command field"
let list parse = function
  | `List values -> List.fold_left (fun result value -> let* values = result in let* value = parse value in Ok (value::values)) (Ok []) values |> Result.map List.rev
  | _ -> Error "expected array"
let route_to_json = function
  | B.Automation_route -> `Assoc ["lane",string "automation"]
  | B.Stagehand_route -> `Assoc ["lane",string "stagehand"]
  | B.Live_route client -> `Assoc ["lane",string "live";"clientId",nullable (fun id -> string (B.client_id_to_string id)) client]
let route_of_json value =
  let* fields = object_fields ["lane";"clientId"] value in
  let* lane = text_field fields "lane" in
  match lane,fields with
  | "automation",[_] -> Ok B.Automation_route
  | "stagehand",[_] -> Ok B.Stagehand_route
  | "live",_ ->
      let* _ = exact ["lane";"clientId"] value in
      let* client = required fields "clientId" in
      let* client = optional (fun value -> let* text = text value in B.client_id_of_string text) client in
      Ok (B.Live_route client)
  | _ -> Error "invalid explicit browser route"
let client_to_json (client : B.client_info) = `Assoc [
  "clientId",string (B.client_id_to_string client.client_id);"browser",string (B.browser_name client.browser);
  "version",string client.version;"engineVersion",string client.engine_version;
  "transport",string (B.live_transport_to_string client.transport)]
let client_of_json value =
  let* fields = exact ["clientId";"browser";"version";"engineVersion";"transport"] value in
  let* raw = text_field fields "clientId" in let* client_id = B.client_id_of_string raw in
  let* raw = text_field fields "browser" in let* browser = B.browser_of_string raw in
  let* raw = text_field fields "transport" in let* transport = B.live_transport_of_string raw in
  let read_version key = let* value = text_field fields key in
    if String.length value<=64 && String.for_all (fun c -> Char.code c>=33 && Char.code c<=126) value
    then Ok value else Error "invalid browser version" in
  let* version = read_version "version" in let* engine_version = read_version "engineVersion" in
  Ok {B.client_id;browser;version;engine_version;transport}
let route_fields route = match route_to_json route with `Assoc fields ->
  List.filter (fun (_,value) -> value<>`Null) fields | _ -> []
let verb_of_json ~route value =
  let* envelope = exact ["verb";"args"] value in
  let* name = text_field envelope "verb" in let* args = required envelope "args" in
  let fields allowed = object_fields allowed args in
  let one_tab make = let* fields = fields ["tabId"] in
    let* value = required fields "tabId" in let* tab_id = tab value in Ok (make tab_id) in
  match name with
  | "tabs.list" -> let* _ = exact [] args in Ok B.Tabs_list
  | "page.read" ->
      let* fields = fields ["tabId";"maxChars";"includeHtml"] in
      let* tab_id = optional_tab fields in
      let* max_chars = optional_field fields "maxChars" integer in
      let* _ = Browser_page_script.text_cap max_chars in
      (match List.assoc_opt "includeHtml" fields with
       | None -> Ok (B.Page_read {tab_id;max_chars})
       | Some (`Bool true) when max_chars=None ->
           (match tab_id with Some tab_id -> Ok (B.Page_document {tab_id}) | None -> Error "document requires tabId")
       | Some _ -> Error "invalid document request")
  | "page.downloads" -> one_tab (fun tab_id -> B.Page_downloads {tab_id})
  | "page.console" -> one_tab (fun tab_id -> B.Page_console {tab_id})
  | "page.network" -> one_tab (fun tab_id -> B.Page_network {tab_id})
  | "page.cookies" -> one_tab (fun tab_id -> B.Page_cookies {tab_id})
  | "page.capture" -> one_tab (fun tab_id -> B.Page_capture {tab_id})
  | "page.elements" -> let* fields = fields ["tabId"] in let* tab_id = optional_tab fields in Ok (B.Page_elements {tab_id})
  | "page.scene" ->
      let* fields = fields ["tabId";"maxChars";"view";"scope"] in
      let* raw = required fields "tabId" in let* tab_id = tab raw in
      let* raw = required fields "maxChars" in let* max_chars = integer raw in
      let* _ = Browser_page_script.text_cap (Some max_chars) in
      let* raw = text_field fields "view" in
      let* view = match raw with "content" -> Ok B.Content | "regions" -> Ok B.Regions | _ -> Error "invalid scene view" in
      let* scope = optional_field fields "scope" Browser_scene.scope_of_json in
      Ok (B.Page_scene {tab_id;max_chars;view;scope})
  | "page.interact" ->
      let* fields = object_fields Browser_interaction.wire_fields args in
      let* request = Browser_interaction.parse (`Assoc (route_fields route @ fields)) in
      Ok (B.Page_interact {tab_id=request.tab_id;expected_url=request.expected_url;action=request.action})
  | "session.open" -> let* fields = fields ["headless"] in let* headless = optional_field fields "headless" boolean in Ok (B.Session_open {headless})
  | "session.close" -> let* _ = exact [] args in Ok B.Session_close
  | "session.status" -> let* _ = exact [] args in Ok B.Session_status
  | "page.goto" -> let* fields = fields ["url";"tabId"] in let* url = text_field fields "url" in
      let* tab_id = optional_tab fields in Ok (B.Page_goto {url;tab_id})
  | "page.act" ->
      let* _ = object_fields ["action";"tabId";"framePath";"url";"selector";"text";"key";"value";"x";"y";"paths"] args in
      B.Action.parse args |> Result.map (fun action -> B.Page_act action)
  | "page.context" ->
      let* fields = fields ["tabId";"framePath";"mode";"maxChars"] in
      let* raw = required fields "tabId" in let* tab_id = tab raw in
      let* frame_path = B.Action.parse_frame_path args in
      let* name = text_field fields "mode" in
      let* mode = match name,List.assoc_opt "maxChars" fields with
        | "text",Some raw -> let* cap = integer raw in let* _ = Browser_page_script.text_cap (Some cap) in Ok (`Text cap)
        | "elements",None -> Ok `Elements | "frames",None -> Ok `Frames | "dialog",None -> Ok `Dialog
        | _ -> Error "invalid context read mode" in
      Ok (B.Page_context {tab_id;frame_path;mode})
  | "page.instruct" -> let* fields = fields ["tabId";"instruction"] in
      let* raw = required fields "tabId" in let* tab_id = tab raw in let* instruction = text_field fields "instruction" in
      Ok (B.Page_instruct {tab_id;instruction})
  | "page.locate" -> let* fields = fields ["tabId";"instruction"] in
      let* raw = required fields "tabId" in let* tab_id = tab raw in let* instruction = optional_field fields "instruction" text in
      Ok (B.Page_locate {tab_id;instruction})
  | "page.extract" -> let* fields = fields ["tabId";"instruction";"schema"] in
      let* raw = required fields "tabId" in let* tab_id = tab raw in let* instruction = text_field fields "instruction" in
      Ok (B.Page_extract {tab_id;instruction;schema=List.assoc_opt "schema" fields})
  | _ -> Error "unknown browser verb"

type command = Snapshot | Retire
  | Upload_stage of {id:string;actor:string;route:B.route;verb:B.verb}
  | Upload_discard of string
  | Download_claim of {id:string;actor:string;route:B.route;verb:B.verb}
  | Download_commit of {id:string;actor:string;route:B.route;verb:B.verb;receipt:Yojson.Safe.t}
  | Download_release of {id:string;actor:string;route:B.route;verb:B.verb}
  | Model_requests | Model_result of Yojson.Safe.t
  | Model_wait of {after:string option} | Poll of {client:B.client_info;window_sec:float}
  | Deliver of {client_id:B.client_id;id:string;payload:Yojson.Safe.t}
  | Disconnect of B.client_id
  | Issue of {route:B.route;verb:B.verb;actor:string option;timeout_sec:float;only_if_idle:bool}
type request = {incarnation:string;command:command}
let to_json request =
  let fields = match request.command with
    | Snapshot -> ["operation",string "snapshot"]
    | Retire -> ["operation",string "retire"]
    | Upload_stage {id;actor;route;verb} -> ["operation",string "upload_stage";"id",string id;
        "actor",string actor;"route",route_to_json route;"command",B.verb_json verb]
    | Upload_discard id -> ["operation",string "upload_discard";"id",string id]
    | Download_claim {id;actor;route;verb} -> ["operation",string "download_claim";"id",string id;
        "actor",string actor;"route",route_to_json route;"command",B.verb_json verb]
    | Download_commit {id;actor;route;verb;receipt} -> ["operation",string "download_commit";"id",string id;
        "actor",string actor;"route",route_to_json route;"command",B.verb_json verb;"receipt",receipt]
    | Download_release {id;actor;route;verb} -> ["operation",string "download_release";"id",string id;
        "actor",string actor;"route",route_to_json route;"command",B.verb_json verb]
    | Model_requests -> ["operation",string "model_requests"]
    | Model_result arguments -> ["operation",string "model_result";"arguments",arguments]
    | Model_wait {after} -> ["operation",string "model_wait";"after",nullable string after]
    | Poll {client;window_sec} -> ["operation",string "poll";"client",client_to_json client;"window_sec",`Float window_sec]
    | Deliver {client_id;id;payload} -> ["operation",string "deliver";"clientId",string (B.client_id_to_string client_id);"id",string id;"payload",payload]
    | Disconnect client_id -> ["operation",string "disconnect";"clientId",string (B.client_id_to_string client_id)]
    | Issue {route;verb;actor;timeout_sec;only_if_idle} -> ["operation",string "issue";"route",route_to_json route;
        "command",B.verb_json verb;"actor",nullable string actor;"timeout_sec",`Float timeout_sec;"only_if_idle",`Bool only_if_idle] in
  `Assoc (("incarnation",string request.incarnation)::fields)
let of_json value =
  let* fields = object_fields ["incarnation";"operation";"receipt";"arguments";"after";"client";"window_sec";"clientId";"id";"payload";"route";"command";"actor";"timeout_sec";"only_if_idle"] value in
  let* incarnation = text_field fields "incarnation" in let* name = text_field fields "operation" in
  let exact keys = exact ("incarnation"::"operation"::keys) value |> Result.map (fun _ -> ()) in
  let client_id () = let* text = text_field fields "clientId" in B.client_id_of_string text in
  let* command = match name with
    | "snapshot" -> let* () = exact [] in Ok Snapshot
    | "retire" -> let* () = exact [] in Ok Retire
    | "upload_stage" ->
        let* ()=exact ["id";"actor";"route";"command"] in
        let* id=text_field fields "id" in let* _=B.client_id_of_string id in
        let* actor=text_field fields "actor" in
        let* raw_route=required fields "route" in let* route=route_of_json raw_route in
        let* command=required fields "command" in
        let* verb=verb_of_json ~route command in Ok (Upload_stage {id;actor;route;verb})
    | "upload_discard" -> let* ()=exact ["id"] in
        let* id=text_field fields "id" in let* _=B.client_id_of_string id in Ok (Upload_discard id)
    | ("download_claim" | "download_commit" | "download_release") as operation ->
        let* ()=exact (["id";"actor";"route";"command"] @
          if operation="download_commit" then ["receipt"] else []) in
        let* id=text_field fields "id" in let* _=B.client_id_of_string id in
        let* actor=text_field fields "actor" in
        let* raw_route=required fields "route" in let* route=route_of_json raw_route in
        let* raw_command=required fields "command" in let* verb=verb_of_json ~route raw_command in
        (match operation with
         | "download_claim" -> Ok (Download_claim {id;actor;route;verb})
         | "download_commit" -> let* receipt=required fields "receipt" in Ok (Download_commit {id;actor;route;verb;receipt})
         | "download_release" -> Ok (Download_release {id;actor;route;verb})
         | _ -> Error "unknown download transfer operation")
    | "model_requests" -> let* () = exact [] in Ok Model_requests
    | "model_result" -> let* () = exact ["arguments"] in
        let* arguments=required fields "arguments" in Ok (Model_result arguments)
    | "model_wait" -> let* () = exact ["after"] in
        let* raw=required fields "after" in let* after=optional text raw in Ok (Model_wait {after})
    | "poll" -> let* () = exact ["client";"window_sec"] in let* raw = required fields "client" in
        let* client = client_of_json raw in let* raw = required fields "window_sec" in let* window_sec = positive raw in Ok (Poll {client;window_sec})
    | "deliver" -> let* () = exact ["clientId";"id";"payload"] in let* client_id = client_id () in
        let* id = text_field fields "id" in let* payload = required fields "payload" in Ok (Deliver {client_id;id;payload})
    | "disconnect" -> let* () = exact ["clientId"] in let* id = client_id () in Ok (Disconnect id)
    | "issue" -> let* () = exact ["route";"command";"actor";"timeout_sec";"only_if_idle"] in
        let* raw = required fields "route" in let* route = route_of_json raw in
        let* raw = required fields "command" in let* verb = verb_of_json ~route raw in
        let* raw = required fields "actor" in let* actor = optional text raw in
        let* raw = required fields "timeout_sec" in let* timeout_sec = positive raw in
        let* raw = required fields "only_if_idle" in let* only_if_idle = boolean raw in
        let* () = if only_if_idle then (match verb with B.Page_document _ -> Ok ()
          | B.Tabs_list|Page_read _|Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_capture _|Page_scene _|Page_interact _|Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act _|Page_context _|Page_instruct _|Page_locate _|Page_extract _ -> Error "idle admission supports document reads only") else Ok () in
        Ok (Issue {route;verb;actor;timeout_sec;only_if_idle})
    | _ -> Error "unknown browser worker operation" in
  Ok {incarnation;command}

let selection_error_to_json error =
  let details = match error with
    | B.Activity_rejected (B.Lane_off lane) -> ["lane", string (B.Lane_name.to_wire lane)]
    | B.Activity_rejected B.Activity_unavailable | B.No_live_client -> []
    | B.Selected_client_disconnected id -> ["clientId", string (B.client_id_to_string id)]
    | B.Ambiguous_clients ids -> ["clients", `List (List.map (fun id -> string (B.client_id_to_string id)) ids)]
    | B.Transport_unsupported {client_id;transport;capability} -> [
        "clientId", string (B.client_id_to_string client_id);
        "transport", string (B.live_transport_to_string transport);
        "capability", string (B.live_capability_to_wire capability)] in
  `Assoc (("error", string (B.selection_error_code error)) :: details)
let selection_error_of_json value =
  let* fields = object_fields ["error";"lane";"clientId";"clients";"transport";"capability"] value in
  let* code = text_field fields "error" in
  let exact keys = exact ("error"::keys) value |> Result.map (fun _ -> ()) in
  let id () = let* raw = text_field fields "clientId" in B.client_id_of_string raw in
  match B.selection_case_of_code code with
  | None -> Error "unknown browser selection error"
  | Some B.Lane_off_case -> let* () = exact ["lane"] in let* raw = text_field fields "lane" in
      let* lane = Option.to_result ~none:"unknown browser lane" (B.Lane_name.of_wire raw) in
      Ok (B.Activity_rejected (B.Lane_off lane))
  | Some B.Activity_unavailable_case -> let* () = exact [] in Ok (B.Activity_rejected B.Activity_unavailable)
  | Some B.No_live_client_case -> let* () = exact [] in Ok B.No_live_client
  | Some B.Selected_client_disconnected_case -> let* () = exact ["clientId"] in
      let* id = id () in Ok (B.Selected_client_disconnected id)
  | Some B.Ambiguous_clients_case -> let* () = exact ["clients"] in
      let* raw = required fields "clients" in
      let* ids = list (fun value -> let* raw = text value in B.client_id_of_string raw) raw in
      Ok (B.Ambiguous_clients ids)
  | Some B.Transport_unsupported_case -> let* () = exact ["clientId";"transport";"capability"] in
      let* client_id = id () in let* raw = text_field fields "transport" in
      let* transport = B.live_transport_of_string raw in let* raw = text_field fields "capability" in
      let* capability = Option.to_result ~none:"unknown browser capability" (B.live_capability_of_wire raw) in
      Ok (B.Transport_unsupported {client_id;transport;capability})
let answer_to_json = function
  | Error error -> `Assoc ["status", string "selection_error"; "error", selection_error_to_json error]
  | Ok answer -> let status, fields = match answer with
      | B.Answered payload -> "answered", ["payload",payload]
      | B.Lane_absent -> "lane_absent", [] | B.Timed_out -> "timed_out", []
      | B.Refused message -> "refused", ["message",string message]
      | B.Rejected_before_effect message -> "rejected_before_effect", ["message",string message] in
      `Assoc (("status",string status)::fields)
let answer_of_json value =
  let* fields = object_fields ["status";"error";"payload";"message"] value in
  let* status = text_field fields "status" in
  let exact keys = exact ("status"::keys) value |> Result.map (fun _ -> ()) in
  match status with
  | "selection_error" -> let* () = exact ["error"] in let* raw = required fields "error" in
      let* error = selection_error_of_json raw in Ok (Error error)
  | "answered" -> let* () = exact ["payload"] in let* payload = required fields "payload" in Ok (Ok (B.Answered payload))
  | "lane_absent" -> let* () = exact [] in Ok (Ok B.Lane_absent)
  | "timed_out" -> let* () = exact [] in Ok (Ok B.Timed_out)
  | "refused" -> let* () = exact ["message"] in let* message = text_field fields "message" in Ok (Ok (B.Refused message))
  | "rejected_before_effect" -> let* () = exact ["message"] in let* message = text_field fields "message" in Ok (Ok (B.Rejected_before_effect message))
  | _ -> Error "unknown browser answer"

type disposition = Not_started | Outcome_unknown
type reply = Snapshot_result of Yojson.Safe.t | Model_reply of Yojson.Safe.t
  | Download_reply of Browser_addon_downloads.claim
  | Poll_result of {command:B.issued option;state_id:string} | Receipt
  | Issue_result of (B.answer, B.selection_error) result
  | Service_refusal of {message:string;disposition:disposition}
let reply_to_json = function
  | Snapshot_result snapshot -> `Assoc ["reply",string "snapshot";"snapshot",snapshot]
  | Model_reply value -> `Assoc ["reply",string "model";"value",value]
  | Download_reply value -> `Assoc ["reply",string "download";"value",Browser_addon_downloads.claim_to_json value]
  | Poll_result {command;state_id} -> `Assoc ["reply",string "poll";"command",nullable (fun (command:B.issued) ->
      `Assoc ["id",string command.id;"command",command.verb_json]) command;"state_id",string state_id]
  | Receipt -> `Assoc ["reply",string "receipt"]
  | Issue_result answer -> `Assoc ["reply",string "issue";"answer",answer_to_json answer]
  | Service_refusal {message;disposition} -> `Assoc ["reply",string "refusal";"message",string message;
      "effect",string (match disposition with Not_started -> "not_started" | Outcome_unknown -> "unknown")]
let reply_of_json value =
  let* fields = object_fields ["reply";"snapshot";"value";"command";"state_id";"answer";"message";"effect"] value in
  let* name = text_field fields "reply" in
  let reply_keys keys = exact ("reply"::keys) value |> Result.map (fun _ -> ()) in
  match name with
  | "snapshot" -> let* () = reply_keys ["snapshot"] in let* snapshot = required fields "snapshot" in Ok (Snapshot_result snapshot)
  | "model" -> let* ()=reply_keys ["value"] in let* value=required fields "value" in Ok (Model_reply value)
  | "download" -> let* ()=reply_keys ["value"] in let* value=required fields "value" in
      let* claim=Browser_addon_downloads.claim_of_json value in Ok (Download_reply claim)
  | "poll" -> let* () = reply_keys ["command";"state_id"] in let* raw = required fields "command" in
      let* command = optional (fun raw -> let* fields = exact ["id";"command"] raw in
        let* id = text_field fields "id" in let* verb_json = required fields "command" in
        Ok {B.id;verb_json}) raw in
      let* state_id = text_field fields "state_id" in Ok (Poll_result {command;state_id})
  | "receipt" -> let* () = reply_keys [] in Ok Receipt
  | "issue" -> let* () = reply_keys ["answer"] in let* raw = required fields "answer" in
      let* answer = answer_of_json raw in Ok (Issue_result answer)
  | "refusal" -> let* () = reply_keys ["message";"effect"] in let* message = text_field fields "message" in
      let* name = text_field fields "effect" in let* disposition = match name with
        | "not_started" -> Ok Not_started | "unknown" -> Ok Outcome_unknown
        | _ -> Error "unknown service refusal disposition" in
      Ok (Service_refusal {message;disposition})
  | _ -> Error "unknown browser service reply"
