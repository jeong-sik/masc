let ( let* ) = Result.bind
let mime = "application/vnd.masc.browser-scene+json"
type t = {
  scene : Browser_scene.t;
  source : Browser_surface.source;
  client_id : Browser_lane.client_id option;
  tab_id : int;
}
let of_json json =
  let* scene = Browser_scene.of_json json in
  match json with
  | `Assoc fields ->
    let* tab_id = match List.assoc_opt "tabId" fields with
      | Some (`Int id) when id >= 0 -> Ok id
      | _ -> Error "observation requires its observed tabId" in
    let* source, client_id =
      match List.assoc_opt "source" fields, List.assoc_opt "clientId" fields with
      | Some (`String "automation"), Some `Null -> Ok (Browser_surface.Automation, None)
      | Some (`String "live"), Some (`String raw) ->
        let* client_id = Browser_lane.client_id_of_string raw in
        Ok (Browser_surface.Live, Some client_id)
      | _ -> Error "observation requires explicit source and resolved client identity" in
    Ok {scene;source;client_id;tab_id}
  | _ -> Error "observation must be an object"

let retain ~base_path ~view result =
  match result with
  | Tool_result.Failed _ | Tool_result.Deferred _ -> Ok result
  | Tool_result.Completed payload ->
    let* observation = of_json payload.data in
    if observation.scene.view <> view then Error "retained observation view mismatch"
    else
      try
        let reference = Tool_blob_store.put_durable
            (Tool_blob_store.create ~base_path)
            ~bytes:(Yojson.Safe.to_string payload.data) ~mime
            |> fun reference -> Tool_output.with_preview reference "" in
        Ok (Tool_result.with_retained_artifacts
          (reference :: payload.retained_artifacts) result)
      with
      | Sys_error detail -> Error detail
      | Unix.Unix_error (error, operation, path) ->
        Error (Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error))
