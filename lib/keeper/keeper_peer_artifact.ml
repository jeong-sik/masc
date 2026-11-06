(* Peer binary handoff uses the workspace blob store, never peer host paths. *)
open Result.Syntax

let reference = Keeper_peer_artifact_ref.of_json

(* Every export is stored with this one media type, so a reference needs no
   copy of it: the sha256 alone finds the bytes. *)
let mime = "application/octet-stream"

type fetched = { blob : Tool_output.artifact_ref; content : string }

type fetch_error = Absent of Keeper_peer_artifact_ref.t | Unreadable of string

let fetch_error_to_string = function
  | Absent artifact -> Printf.sprintf "Exported artifact %s is absent" (artifact :> string)
  | Unreadable detail -> detail

let fetch_error_class = function
  | Absent _ -> Tool_result.Workflow_rejection
  | Unreadable _ -> Tool_result.Runtime_failure

let fetch ~config (artifact : Keeper_peer_artifact_ref.t) =
  let sha256 = (artifact :> string) in
  let* content = Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.Workspace.base_path)
      ~sha256 |> Result.map_error (fun error -> Unreadable (Tool_blob_store.fetch_error_to_string error)) in
  match content with
  | None -> Error (Absent artifact)
  | Some content ->
    Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length content) ~preview:"" ~mime
    |> Result.map (fun blob -> { blob; content })
    |> Result.map_error (fun error -> Unreadable (Tool_output.make_error_to_string error))

let materialize ~base_path ~(artifact : Keeper_peer_artifact_ref.t) ~path ~fetch ~read ~write =
  let carried_data = function None -> [] | Some data -> ["write_result", data] in
  let persist_result ~blobs ~effect_disposition ~retained_artifacts result =
    let roots = blobs @ retained_artifacts
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
  let failure ~class_ ~blobs ?metadata ?write_result ?file_change_evidence ?(retained_artifacts = []) ~effect_disposition detail =
    Tool_result.make_err ~tool_name:"keeper_artifact_transfer" ~start_time:(Tool_timing.start ())
      ~class_ ~effect_disposition ?metadata
      ~data:(`Assoc (["path", `String path;
                "artifact", Keeper_peer_artifact_ref.to_json artifact] @ carried_data write_result
        @ (match file_change_evidence with
           | None -> []
           | Some evidence -> ["write_evidence", Keeper_file_change_evidence.to_yojson evidence])))
      detail
    |> persist_result ~blobs ~effect_disposition ~retained_artifacts
  in
  match fetch () with
  | Error error ->
    failure ~class_:(fetch_error_class error) ~blobs:[] ~effect_disposition:Tool_result.Proven_pre_effect
      (fetch_error_to_string error)
  | Ok { blob; content = expected } ->
    (* From here on every result this call builds, and a verified writer
       success, keeps the fetched blob in this call's ledger row: the call
       names it by sha256 alone, which the blob GC does not count. *)
    let blobs = [ blob ] in
    (* Read one byte past the expected length: a matching prefix is not proof
       that the recipient has exactly this artifact. The fetched string
       bounds the allocation. *)
    let observe () = read ~max_bytes:(String.length expected + 1) in
    let receipt ?metadata ?write_result ?(retained_artifacts = []) ~recovered () =
      Tool_result.make_ok ~tool_name:"keeper_artifact_transfer" ~start_time:(Tool_timing.start ()) ?metadata
        ~data:(`Assoc (["ok", `Bool true; "path", `String path;
                 "mode", `String "overwrite"; "bytes", `Int (String.length expected);
                 "write_attempted", `Bool recovered;
                 "verified", `Bool true; "recovered", `Bool recovered;
                 "artifact", Keeper_peer_artifact_ref.to_json artifact] @ carried_data write_result)) ()
      |> persist_result ~blobs ~retained_artifacts
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
         | Ok actual when String.equal actual expected ->
           Keeper_tool_execution.with_retained_artifacts (blobs @ result.retained_artifacts) result
         | Ok _ ->
           failure ~class_:Tool_result.Runtime_failure ~blobs ?metadata:result.metadata ?write_result:result.data ~retained_artifacts:result.retained_artifacts
             ?file_change_evidence:result.file_change_evidence
             ~effect_disposition:Tool_result.Proven_post_effect
             "Artifact write completed, but recipient bytes differ. Inspect the recipient; do not blindly repeat the write."
         | Error error ->
           failure ~class_:Tool_result.Runtime_failure ~blobs ?metadata:result.metadata ?write_result:result.data ~retained_artifacts:result.retained_artifacts
             ?file_change_evidence:result.file_change_evidence
             ~effect_disposition:Tool_result.Proven_post_effect
             ("Artifact write completed, but recipient verification failed: "
              ^ Keeper_sandbox_read_backend.read_error_to_string error))
    in
    match observe () with
    | Ok actual when String.equal actual expected -> receipt ~recovered:false ()
    | Ok _ | Error (Keeper_sandbox_read_backend.Missing_file _) -> after_write (write blob)
    | Error (Keeper_sandbox_read_backend.Not_a_file detail
            | Keeper_sandbox_read_backend.Read_refused detail) ->
      Keeper_tool_execution.failure ~class_:Tool_result.Workflow_rejection
        ~effect_disposition:Tool_result.Proven_pre_effect detail
      |> Keeper_tool_execution.with_retained_artifacts blobs
    | Error (Keeper_sandbox_read_backend.Read_failed detail) ->
      failure ~class_:Tool_result.Runtime_failure ~blobs ~effect_disposition:Tool_result.Proven_pre_effect detail

let handle ~config ~meta ~turn_sandbox_factory ~write ~args =
  let fail class_ detail = Keeper_tool_execution.failure ~class_ detail in
  match Keeper_peer_artifact_request.of_json args with
  | Error detail -> fail Tool_result.Policy_rejection detail
  | Ok (Keeper_peer_artifact_request.Export { path }) ->
    (* The Keeper names the path, so the size is the Keeper's choice, and the
       bytes end up durable in the blob store. Read one past the ceiling: at
       exactly the ceiling a file that fits and a file that was cut look the
       same, and the sha256 of cut bytes is as good an address as the whole
       file's, so nothing after this point could tell them apart. So an
       oversize file is refused, never shortened. *)
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
              (Tool_blob_store.create ~base_path:config.Workspace.base_path) ~bytes ~mime in
          (* The result names the blob by sha256 alone, which the blob GC does
             not count as a reference. This call's ledger row keeps it alive
             through the retained artifact for as long as the ledger keeps the
             row (the operator retention window). *)
          Tool_result.make_ok ~tool_name:"keeper_artifact_transfer" ~start_time:(Tool_timing.start ())
            ~data:(`Assoc ["artifact", Keeper_peer_artifact_ref.(to_json (of_blob blob))]) ()
          |> Keeper_tool_execution.of_tool_result
          |> Keeper_tool_execution.with_retained_artifacts [ blob ]
        with Sys_error detail -> fail Tool_result.Runtime_failure detail))
  | Ok (Keeper_peer_artifact_request.Materialize { path; artifact }) ->
    materialize ~base_path:config.Workspace.base_path ~artifact ~path ~fetch:(fun () -> fetch ~config artifact)
      ~read:(fun ~max_bytes ->
        Keeper_tool_filesystem_runtime.read_sandbox_raw_prefix ?turn_sandbox_factory
          ~config ~meta ~path ~max_bytes ())
      ~write:(fun blob ->
        write (`Assoc ["path", `String path; "mode", `String "overwrite";
                      "content_artifact", Tool_output.normalized_artifact_ref_to_json blob]))
