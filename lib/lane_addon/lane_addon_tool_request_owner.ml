let ( let* ) = Result.bind
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
  | Invalid_request of string
type retained = {
  scope : string; request_id : string; installation_id : string;
  package_id : string; tool : string; request_digest : string; request : Yojson.Safe.t;
}
let schema = "lane.addon.tool-request-owner.v1"
let validate_identity fields =
  match List.find_opt (fun (_, value) -> String.trim value = "") fields with
  | None -> Ok ()
  | Some (field, _) -> Error (Invalid_identity field)
let digest request = Lane_addon_store.digest (Yojson.Safe.to_string request)
let to_json (r : retained) = `Assoc ["schema", `String schema;
  "scope", `String r.scope; "request_id", `String r.request_id;
  "installation_id", `String r.installation_id; "package_id", `String r.package_id;
  "tool", `String r.tool; "request_digest", `String r.request_digest; "request", r.request]
let decode ~scope ~request_id json =
  let* fields = match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields) =
        List.sort String.compare ["schema"; "scope"; "request_id";
          "installation_id"; "package_id"; "tool"; "request_digest"; "request"] -> Ok fields
    | _ -> Error "invalid original request record fields" in
  let text key = match List.assoc key fields with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error ("invalid original request " ^ key) in
  let* version = text "schema" in
  let* () = if String.equal version schema then Ok () else Error "unknown original request schema" in
  let* stored_scope = text "scope" in
  let* stored_id = text "request_id" in
  let* () = if String.equal stored_scope scope && String.equal stored_id request_id then Ok ()
    else Error "original request does not match its storage key" in
  let* installation_id = text "installation_id" in
  let* package_id = text "package_id" in
  let* tool = text "tool" in
  let* request_digest = text "request_digest" in
  let* request = Lane_addon_action.canonical (List.assoc "request" fields) in
  if not (String.equal request_digest (digest request)) then Error "original request digest mismatch"
  else Ok {scope; request_id; installation_id; package_id; tool; request_digest; request}
let load ~store ~scope ~request_id =
  let* () = validate_identity ["scope", scope; "request_id", request_id] in
  let* previous = Lane_addon_store.load_tool_request_owner store ~scope ~request_id
    |> Result.map_error (fun detail -> Store_unavailable detail) in
  match previous with
  | None -> Ok None
  | Some json -> decode ~scope ~request_id json
      |> Result.map Option.some |> Result.map_error (fun detail -> Store_unavailable detail)
let retain ~store ~scope ~request_id ~installation_id ~package_id ~tool ~request =
  let* () = validate_identity ["scope", scope; "request_id", request_id;
    "installation_id", installation_id; "package_id", package_id; "tool", tool] in
  let* request = Lane_addon_action.canonical request
    |> Result.map_error (fun detail -> Invalid_request detail) in
  let expected = {scope; request_id; installation_id; package_id; tool;
    request_digest = digest request; request} in
  let* previous = load ~store ~scope ~request_id in
  match previous with
  | Some previous -> if previous = expected then Ok () else Error Binding_conflict
  | None -> Lane_addon_store.save_tool_request_owner store ~scope ~request_id (to_json expected)
      |> Result.map_error (fun detail -> Store_unavailable detail)
let error_to_string = function
  | Binding_conflict -> "Original Add-on request is bound to another installation, tool or captured input"
  | Store_unavailable detail -> "Add-on request ownership unavailable: " ^ detail
  | Invalid_identity field -> "Add-on request ownership requires " ^ field
  | Invalid_request detail -> "Invalid captured Add-on request: " ^ detail
