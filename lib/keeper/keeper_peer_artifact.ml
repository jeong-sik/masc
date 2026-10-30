(* Peer binary handoff uses the workspace blob store, never peer host paths. *)
open Result.Syntax

let reference = Keeper_peer_artifact_ref.of_json

let fetch ~config (descriptor : Keeper_peer_artifact_ref.t) =
  let reference = descriptor.blob in
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.Workspace.base_path)
      ~sha256:reference.sha256 |> Result.map_error Tool_blob_store.fetch_error_to_string in
  match bytes with
  | None -> Error "Exported artifact is absent"
  | Some bytes when String.length bytes = reference.bytes -> Ok bytes
  | Some _ -> Error "Exported artifact size differs from its reference"

let materialize ~base_path ~(artifact : Keeper_peer_artifact_ref.t) ~path ~fetch ~read ~write =
  let carried_data = function None -> [] | Some data -> ["write_result", data] in
  let persist_result ~effect_disposition ~retained_artifacts result =
    let roots = artifact.blob :: retained_artifacts
      @ Tool_output.normalized_artifact_refs_in_json (Tool_result.data result)
      @ (match Tool_result.metadata result with None -> []
         | Some metadata -> Tool_output.normalized_artifact_refs_in_json metadata) in
    let execution = match Tool_bridge.attach_artifact_manifest ~base_path result with
      | Ok manifested -> Keeper_tool_execution.of_tool_result
          ~failure_effect_disposition:effect_disposition manifested
      | Error error ->
        (* The old writer manifest describes a different payload. Keep its
           metadata as evidence, never as this failed publication's binding. *)
        Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
          ~effect_disposition
          ~message:("Peer artifact result manifest could not be stored: " ^ error.message
                    ^ ". The recorded effect phase remains authoritative; do not blindly repeat the write.")
          (`Assoc (["result", Tool_result.data result;
                    "result_message", `String (Tool_result.message result)]
                   @ match Tool_result.metadata result with
                     | None -> [] | Some metadata -> ["producer_metadata", metadata]))
    in
    Keeper_tool_execution.with_retained_artifacts roots execution
  in
  let failure ?metadata ?write_result ?file_change_evidence ?(retained_artifacts = []) ~effect_disposition detail =
    Tool_result.make_err ~tool_name:"keeper_artifact_transfer" ~start_time:(Tool_timing.start ())
      ~class_:Tool_result.Runtime_failure ~effect_disposition ?metadata
      ~data:(`Assoc (["path", `String path;
                "artifact", Keeper_peer_artifact_ref.to_json artifact] @ carried_data write_result
        @ (match file_change_evidence with
           | None -> []
           | Some evidence -> ["write_evidence", Keeper_file_change_evidence.to_yojson evidence])))
      detail
    |> persist_result ~effect_disposition ~retained_artifacts
  in
  match fetch () with
  | Error detail -> failure ~effect_disposition:Tool_result.Proven_pre_effect detail
  | Ok expected ->
    (* Read one byte past the expected length: a matching prefix is not proof
       that the recipient has exactly this artifact. The fetched string, not
       an untrusted descriptor size, bounds the allocation. *)
    let observe () = read ~max_bytes:(String.length expected + 1) in
    let receipt ?metadata ?write_result ?(retained_artifacts = []) ~recovered () =
      Tool_result.make_ok ~tool_name:"keeper_artifact_transfer" ~start_time:(Tool_timing.start ()) ?metadata
        ~data:(`Assoc (["ok", `Bool true; "path", `String path;
                 "mode", `String "overwrite"; "bytes", `Int (String.length expected);
                 "write_attempted", `Bool recovered;
                 "verified", `Bool true; "recovered", `Bool recovered;
                 "artifact", Keeper_peer_artifact_ref.to_json artifact] @ carried_data write_result)) ()
      |> persist_result ~retained_artifacts
        ~effect_disposition:(if recovered then Tool_result.Proven_post_effect else Tool_result.Proven_pre_effect)
    in
    let after_write result =
      match result.Keeper_tool_execution.disposition with
      | Tool_result.Deferred _
      | Tool_result.Failed (Tool_result.Policy_rejection | Tool_result.Workflow_rejection
                         | Tool_result.Dependency_unavailable | Tool_result.Operator_cancelled) -> result
      | Tool_result.Failed Tool_result.Runtime_failure ->
        (match result.failure_effect_disposition with
         | Tool_result.Proven_pre_effect -> result
         | Tool_result.Effect_outcome_unknown | Tool_result.Proven_post_effect ->
           (match observe () with
            | Ok actual when String.equal actual expected ->
              receipt ?metadata:result.metadata ?write_result:result.data ~retained_artifacts:result.retained_artifacts
                ~recovered:true ()
            | Ok _ | Error _ -> result))
      | Tool_result.Completed () ->
        (match observe () with
         | Ok actual when String.equal actual expected -> result
         | Ok _ ->
           failure ?metadata:result.metadata ?write_result:result.data ~retained_artifacts:result.retained_artifacts
             ?file_change_evidence:result.file_change_evidence
             ~effect_disposition:Tool_result.Proven_post_effect
             "Artifact write completed, but recipient bytes differ. Inspect the recipient; do not blindly repeat the write."
         | Error error ->
           failure ?metadata:result.metadata ?write_result:result.data ~retained_artifacts:result.retained_artifacts
             ?file_change_evidence:result.file_change_evidence
             ~effect_disposition:Tool_result.Proven_post_effect
             ("Artifact write completed, but recipient verification failed: "
              ^ Keeper_sandbox_read_backend.read_error_to_string error))
    in
    match observe () with
    | Ok actual when String.equal actual expected -> receipt ~recovered:false ()
    | Ok _ | Error (Keeper_sandbox_read_backend.Missing_file _) -> after_write (write ())
    | Error (Keeper_sandbox_read_backend.Not_a_file detail
            | Keeper_sandbox_read_backend.Read_refused detail) ->
      Keeper_tool_execution.failure ~class_:Tool_result.Workflow_rejection
        ~effect_disposition:Tool_result.Proven_pre_effect detail
    | Error (Keeper_sandbox_read_backend.Read_failed detail) ->
      failure ~effect_disposition:Tool_result.Proven_pre_effect detail

let handle ~config ~meta ~turn_sandbox_factory ~write ~args =
  let fail class_ detail = Keeper_tool_execution.failure ~class_ detail in
  match Keeper_peer_artifact_request.of_json args with
  | Error detail -> fail Tool_result.Policy_rejection detail
  | Ok (Keeper_peer_artifact_request.Export { path; purpose }) ->
    (* The Keeper names the path, so the size is the Keeper's choice, and the
       bytes end up durable in the blob store. Read one past the ceiling: at
       exactly the ceiling a file that fits and a file that was cut look the
       same, and a cut export would still satisfy the size check its own
       reference records -- [fetch] compares against [reference.bytes], which
       was written from the cut length. So an oversize file is refused, never
       shortened. *)
    let ceiling = Env_config_keeper.KeeperPeerArtifact.max_bytes () in
    (match Keeper_tool_filesystem_runtime.read_sandbox_raw_prefix ?turn_sandbox_factory
        ~config ~meta ~path ~max_bytes:(ceiling + 1) () with
     | Error (Keeper_sandbox_read_backend.Missing_file detail)
     | Error (Keeper_sandbox_read_backend.Not_a_file detail) ->
       fail Tool_result.Workflow_rejection detail
     | Error (Keeper_sandbox_read_backend.Read_refused detail) ->
       fail Tool_result.Workflow_rejection detail
     | Error (Keeper_sandbox_read_backend.Read_failed detail) ->
       fail Tool_result.Runtime_failure detail
     | Ok bytes when String.length bytes > ceiling ->
       fail Tool_result.Policy_rejection
         (Printf.sprintf
            "Exported artifact is larger than %d bytes; export a smaller file \
             or raise MASC_KEEPER_PEER_ARTIFACT_MAX_BYTES"
            ceiling)
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
                  ~start_time:(Tool_timing.start ()) ~data () in
              match Tool_bridge.attach_artifact_manifest ~base_path:config.base_path result with
              | Ok result -> Keeper_tool_execution.of_tool_result result
              | Error error ->
                Log.Keeper.error "exported peer artifact result manifest unavailable: %s" error.message;
                Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
                  ~effect_disposition:Tool_result.Proven_post_effect
                  ~message:"The artifact was exported, but its result manifest could not be stored. Read the recorded artifact; do not repeat the export."
                  data)
        with Sys_error detail -> fail Tool_result.Runtime_failure detail))
  | Ok (Keeper_peer_artifact_request.Materialize { path; artifact }) ->
    materialize ~base_path:config.Workspace.base_path ~artifact ~path ~fetch:(fun () -> fetch ~config artifact)
      ~read:(fun ~max_bytes ->
        Keeper_tool_filesystem_runtime.read_sandbox_raw_prefix ?turn_sandbox_factory
          ~config ~meta ~path ~max_bytes ())
      ~write:(fun () ->
        write (`Assoc ["path", `String path; "mode", `String "overwrite";
                      "content_artifact", Tool_output.normalized_artifact_ref_to_json artifact.blob]))
