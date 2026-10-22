let ( let* ) = Result.bind
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
  | Invalid_request of string
type retained = {
  scope : string; request_id : string; installation_id : string;
  package_id : string; tool : string; request_digest : string; request : Yojson.Safe.t;
  progress : Lane_addon_request_progress.t;
}
let schema = "lane.addon.tool-request-owner.v2"
let validate_identity fields =
  match List.find_opt (fun (_, value) -> String.trim value = "") fields with
  | None -> Ok ()
  | Some (field, _) -> Error (Invalid_identity field)
let digest request = Lane_addon_store.digest (Yojson.Safe.to_string request)
let to_json (r : retained) = `Assoc ["schema", `String schema;
  "scope", `String r.scope; "request_id", `String r.request_id;
  "installation_id", `String r.installation_id; "package_id", `String r.package_id;
  "tool", `String r.tool; "request_digest", `String r.request_digest; "request", r.request;
  "progress", Lane_addon_request_progress.to_json r.progress]
let decode ~scope ~request_id json =
  let* fields = match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields) =
        List.sort String.compare ["schema"; "scope"; "request_id";
          "installation_id"; "package_id"; "tool"; "request_digest"; "request"; "progress"] -> Ok fields
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
  let* progress = Lane_addon_request_progress.of_json (List.assoc "progress" fields) in
  if not (String.equal request_digest (digest request)) then Error "original request digest mismatch"
  else Ok {scope; request_id; installation_id; package_id; tool; request_digest; request; progress}
let load ~store ~scope ~request_id =
  let* () = validate_identity ["scope", scope; "request_id", request_id] in
  let* previous = Lane_addon_store.load_tool_request_owner store ~scope ~request_id
    |> Result.map_error (fun detail -> Store_unavailable detail) in
  match previous with
  | None -> Ok None
  | Some json -> decode ~scope ~request_id json
      |> Result.map Option.some |> Result.map_error (fun detail -> Store_unavailable detail)
let discover ~store ~scope =
  let* () = validate_identity ["scope",scope] in
  let* rows = Lane_addon_store.tool_request_owner_inventory store ~scope
    |> Result.map_error (fun detail -> Store_unavailable detail) in
  let rec restore records = function
    | [] -> Ok (List.rev records)
    | (name,json) :: rest ->
      let* request_id = (match json with
        | `Assoc fields -> (match List.assoc_opt "request_id" fields with
            | Some (`String value) when String.trim value <> "" -> Ok value
            | _ -> Error "missing original request ID")
        | _ -> Error "invalid original request record")
        |> Result.map_error (fun detail -> Store_unavailable detail) in
      let* record = decode ~scope ~request_id json
        |> Result.map_error (fun detail -> Store_unavailable detail) in
      if not (String.equal name (Lane_addon_store.digest request_id ^ ".json"))
      then Error (Store_unavailable "original request filename does not match its ID")
      else restore (record :: records) rest in
  restore [] rows
let retain ~store ~scope ~request_id ~installation_id ~package_id ~tool ~request =
  let* () = validate_identity ["scope", scope; "request_id", request_id;
    "installation_id", installation_id; "package_id", package_id; "tool", tool] in
  let* request = Lane_addon_action.canonical request
    |> Result.map_error (fun detail -> Invalid_request detail) in
  let expected = {scope; request_id; installation_id; package_id; tool;
    request_digest = digest request; request; progress=Lane_addon_request_progress.captured} in
  let* previous = load ~store ~scope ~request_id in
  match previous with
  | Some previous ->
    (* Retaining the immutable input must not reset an already advancing tail. *)
    if {previous with progress=Lane_addon_request_progress.captured} = expected
    then Ok () else Error Binding_conflict
  | None -> Lane_addon_store.save_tool_request_owner store ~scope ~request_id (to_json expected)
      |> Result.map_error (fun detail -> Store_unavailable detail)
type update_error = Ownership_error of error | State_conflict | Invalid_transition of string
type publication = Stored of retained | Already_stored of retained | Unconfirmed of string
let advance ~store ~(expected : retained) ~event =
  let* progress = Lane_addon_request_progress.append expected.progress event
    |> Result.map_error (fun detail -> Invalid_transition detail) in
  let next = {expected with progress} in
  let* previous = load ~store ~scope:expected.scope ~request_id:expected.request_id
    |> Result.map_error (fun error -> Ownership_error error) in
  match previous with
  | None -> Error State_conflict
  | Some previous ->
    if previous = next then Ok (Already_stored previous)
    else if previous <> expected then Error State_conflict
    else match Lane_addon_store.save_tool_request_owner store
        ~scope:expected.scope ~request_id:expected.request_id (to_json next) with
      | Ok () -> Ok (Stored next)
      | Error detail -> Ok (Unconfirmed detail)
let error_to_string = function
  | Binding_conflict -> "Original Add-on request is bound to another installation, tool or captured input"
  | Store_unavailable detail -> "Add-on request ownership unavailable: " ^ detail
  | Invalid_identity field -> "Add-on request ownership requires " ^ field
  | Invalid_request detail -> "Invalid captured Add-on request: " ^ detail
let update_error_to_string = function
  | Ownership_error error -> error_to_string error
  | State_conflict -> "Original Add-on request changed before progress publication"
  | Invalid_transition detail -> "Invalid Add-on request progress: " ^ detail
