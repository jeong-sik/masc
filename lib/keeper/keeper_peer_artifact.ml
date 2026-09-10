(* Peer binary handoff uses the workspace blob store, never peer host paths. *)
let ( let* ) = Result.bind

let reference json =
  match Tool_output.normalized_artifact_ref_of_json json with
  | Tool_output.Decoded_normalized_artifact_ref reference -> Ok reference
  | Tool_output.Invalid_normalized_artifact_ref {detail} -> Error detail
  | Tool_output.Not_normalized_artifact_ref -> Error "Expected an exported _blob reference"

let fetch ~config (reference : Tool_output.artifact_ref) =
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.Workspace.base_path)
      ~sha256:reference.sha256 |> Result.map_error Tool_blob_store.fetch_error_to_string in
  match bytes with
  | None -> Error "Exported artifact is absent"
  | Some bytes when String.length bytes = reference.bytes -> Ok bytes
  | Some _ -> Error "Exported artifact size differs from its reference"

let relative_path path =
  path <> "" && Filename.is_relative path
  && List.for_all (fun part -> part <> ".." && part <> "" && part <> ".")
       (String.split_on_char '/' path)

let handle ~config ~meta ~turn_sandbox_factory ~write ~args =
  let fail detail = Keeper_tool_execution.failure ~class_:Tool_result.Workflow_rejection detail in
  let path = Json_util.get_string args "path" |> Option.value ~default:"" in
  if not (relative_path path) then fail "Artifact path must be relative to this Keeper's sandbox"
  else match Json_util.get_string args "action" with
  | Some "export" ->
    (match Keeper_tool_filesystem_runtime.read_sandbox_bytes ?turn_sandbox_factory
        ~config ~meta ~path ~max_bytes:max_int with
     | Error detail -> fail detail
     | Ok bytes ->
       (try
          let reference = Tool_blob_store.put_durable
              (Tool_blob_store.create ~base_path:config.Workspace.base_path)
              ~bytes ~mime:"application/octet-stream" in
          Keeper_tool_execution.success_data
            (`Assoc ["artifact", Tool_output.normalized_artifact_ref_to_json reference;
                     "filename", `String (Filename.basename path)])
        with Sys_error detail -> fail detail))
  | Some "materialize" ->
    let prepared =
      let* reference = reference (Yojson.Safe.Util.member "artifact" args) in
      let* bytes = fetch ~config reference in
      Ok bytes in
    (match prepared with
     | Error detail -> fail detail
     | Ok _ -> write (`Assoc ["path", `String path; "mode", `String "overwrite";
                                 "content_artifact", Yojson.Safe.Util.member "artifact" args]))
  | Some _ | None -> fail "action must be export or materialize"
