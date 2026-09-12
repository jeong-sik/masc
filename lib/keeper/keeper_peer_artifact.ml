(* Peer binary handoff uses the workspace blob store, never peer host paths. *)
let ( let* ) = Result.bind

let reference = Keeper_peer_artifact_ref.of_json

let fetch ~config (descriptor : Keeper_peer_artifact_ref.t) =
  let reference = descriptor.blob in
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

type request = Export of {path:string; purpose:string} | Materialize of {path:string; artifact:Keeper_peer_artifact_ref.t}
let decode = function
  | `Assoc fields ->
    (match List.assoc_opt "path" fields with
     | Some (`String path) when relative_path path ->
       (match List.assoc_opt "action" fields with
        | Some (`String "export") ->
          (match List.assoc_opt "purpose" fields, List.assoc_opt "artifact" fields with
           | Some (`String purpose), None when String.trim purpose <> "" -> Ok (Export {path; purpose})
           | _ -> Error "Export requires a purpose and no artifact")
        | Some (`String "materialize") ->
          (match List.assoc_opt "artifact" fields with
           | Some json -> let* artifact = reference json in Ok (Materialize {path; artifact})
           | None -> Error "Materialize requires an artifact")
        | _ -> Error "action must be export or materialize")
     | _ -> Error "path must be a nonempty relative sandbox path")
  | _ -> Error "Artifact request must be an object"
let handle ~config ~meta ~turn_sandbox_factory ~write ~args =
  let fail class_ detail = Keeper_tool_execution.failure ~class_ detail in
  match decode args with
  | Error detail -> fail Tool_result.Policy_rejection detail
  | Ok (Export {path; purpose}) ->
    (match Keeper_tool_filesystem_runtime.read_complete_sandbox_bytes ?turn_sandbox_factory
        ~config ~meta ~path () with
     | Error detail -> fail Tool_result.Runtime_failure detail
     | Ok bytes ->
       (try
          let blob = Tool_blob_store.put_durable
              (Tool_blob_store.create ~base_path:config.Workspace.base_path)
              ~bytes ~mime:"application/octet-stream" in
          match Keeper_peer_artifact_ref.make ~blob ~filename:(Filename.basename path) ~purpose with
          | Error detail -> fail Tool_result.Policy_rejection detail
          | Ok artifact ->
            (* The exported bytes are durable already. Preserve the result
               manifest at this producer boundary before the model projection
               replaces normalized references with its durable manifest. *)
            Eio.Cancel.protect (fun () ->
              let data = `Assoc ["artifact", Keeper_peer_artifact_ref.to_json artifact] in
              let result = Tool_result.make_ok ~tool_name:"keeper_artifact_transfer"
                  ~start_time:(Time_compat.now ()) ~data () in
              match Tool_bridge.attach_artifact_manifest ~base_path:config.base_path result with
              | Ok result -> Keeper_tool_execution.of_tool_result result
              | Error error ->
                Log.Keeper.error "exported peer artifact result manifest unavailable: %s" error.message;
                Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
                  ~effect_disposition:Tool_result.Proven_post_effect
                  ~message:"The artifact was exported, but its result manifest could not be stored. Read the recorded artifact; do not repeat the export."
                  data)
        with Sys_error detail -> fail Tool_result.Runtime_failure detail))
  | Ok (Materialize {path; artifact}) ->
    write (`Assoc ["path", `String path; "mode", `String "overwrite";
                  "content_artifact", Tool_output.normalized_artifact_ref_to_json artifact.blob])
