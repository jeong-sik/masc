let ( let* ) = Result.bind
let persist ~keeper_name json =
  let string key = match json with
    | `Assoc fields -> (match List.assoc_opt key fields with
        | Some (`String value) -> Ok value | _ -> Error ("screenshot missing " ^ key))
    | _ -> Error "screenshot must be an object" in
  let* encoded = string "data" in
  let* url = string "url" in
  let* title = string "title" in
  let* tab_id = match json with
    | `Assoc fields -> (match List.assoc_opt "tabId" fields with
        | Some (`Int id) when id >= 0 -> Ok id | _ -> Error "screenshot missing tabId")
    | _ -> Error "screenshot must be an object" in
  let* client_fields = match json with
    | `Assoc fields ->
      (match List.assoc_opt "clientId" fields with
       (* Direct pixel persistence may omit routing metadata. Never invent an identity. *)
       | None -> Ok []
       | Some `Null -> Ok ["clientId", `Null]
       | Some (`String raw) ->
         let* id = Browser_lane.client_id_of_string raw in
         Ok ["clientId", `String (Browser_lane.client_id_to_string id)]
       | Some _ -> Error "invalid screenshot clientId")
    | _ -> Error "screenshot must be an object" in
  let* observation_fields = match json with
    | `Assoc fields ->
      let* viewport_fields = match List.assoc_opt "viewport" fields with
        | None -> Ok []
        | Some value ->
          let* viewport = Browser_lane.Pointer.viewport_of_json value in
          Ok ["viewport", Browser_lane.Pointer.viewport_to_json viewport] in
      let* source_fields = match List.assoc_opt "source" fields with
        | None -> Ok []
        | Some (`String ("live" | "automation" as source)) ->
          Ok ["source", `String source]
        | Some _ -> Error "invalid screenshot source" in
      Ok (source_fields @ viewport_fields)
    | _ -> Error "screenshot must be an object" in
  let max_bytes = Keeper_vision_tool.max_image_bytes () in
  if String.length encoded > ((max_bytes + 2) / 3) * 4 then Error "screenshot exceeds Vision image size limit"
  else
    let* bytes = match Base64.decode encoded with Ok bytes -> Ok bytes | Error (`Msg _) -> Error "invalid screenshot base64" in
    let* () = Keeper_vision_tool.validate_image_size bytes in
    let* mime = Keeper_vision_tool.sniff_image_media_type bytes in
    if mime <> "image/png" then Error "browser screenshot must be PNG"
    else
      let* width, height = match Keeper_image_dimensions.image_dimensions bytes with
        | Some (width,height) when width > 0 && height > 0 -> Ok (width,height)
        | _ -> Error "invalid screenshot dimensions" in
      let* handle = Keeper_vision_tool.store_artifact
          ~dir:(Keeper_vision_tool.vision_store_dir ~keeper_name) bytes in
      Ok (`Assoc (client_fields @ observation_fields @ ["artifact", `String (Multimodal.Vision_artifact_store.to_string handle);
        "media_type", `String mime; "tabId", `Int tab_id; "url", `String url;
        "title", `String title; "width", `Int width; "height", `Int height;
        "bytes", `Int (String.length bytes); "scope", `String "viewport"]))
