let ( let* ) = Result.bind
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
let retain ~store ~scope ~request_id ~installation_id ~package_id ~tool ~request =
  let* () = match List.find_opt (fun (_, value) -> String.trim value = "")
      ["scope",scope;"request_id",request_id;"installation_id",installation_id;"package_id",package_id;"tool",tool] with
    | None -> Ok () | Some (field,_) -> Error (Invalid_identity field) in
  let digest = Lane_addon_store.digest (Yojson.Safe.to_string (Yojson.Safe.sort request)) in
  let expected = `Assoc ["scope",`String scope;"request_id",`String request_id;
    "installation_id",`String installation_id;"package_id",`String package_id;
    "tool",`String tool;"request_digest",`String digest] in
  let* previous = Lane_addon_store.load_tool_request_owner store ~scope ~request_id
    |> Result.map_error (fun detail -> Store_unavailable detail) in
  match previous with
  | Some previous -> if Yojson.Safe.equal previous expected then Ok () else Error Binding_conflict
  | None -> Lane_addon_store.save_tool_request_owner store ~scope ~request_id expected
    |> Result.map_error (fun detail -> Store_unavailable detail)
let error_to_string = function
  | Binding_conflict -> "Original Add-on request is bound to another installation, tool or captured input"
  | Store_unavailable detail -> "Add-on request ownership unavailable: " ^ detail
  | Invalid_identity field -> "Add-on request ownership requires " ^ field
