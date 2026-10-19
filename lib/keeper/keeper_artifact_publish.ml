let fail class_ message = Keeper_tool_execution.failure ~class_ message

let handle_with_manifest ~persist_manifest ~base_path ~author ~args =
  let start_time = Tool_timing.start () in
  match Published_artifact.request_of_json args with
  | Error message -> fail Tool_result.Policy_rejection message
  | Ok request ->
    match Published_artifact_store.publish ~base_path ~author request with
    | Ok (artifact, revision) ->
      (* Publication has committed. Preserve its receipt before model delivery;
         a normalized body reference needs a durable result manifest too. *)
      Eio.Cancel.protect (fun () ->
        let data = Published_artifact.publication_to_json ~id:artifact.id revision in
        let result = Tool_result.make_ok ~tool_name:"keeper_artifact_publish"
            ~start_time ~data ()
          |> Tool_result.with_retained_artifacts [revision.body] in
        match persist_manifest ~base_path result with
        | Ok result -> Keeper_tool_execution.of_tool_result result
        | Error (error : Tool_bridge.externalization_error) ->
          Log.Keeper.error "published report result manifest unavailable: %s" error.message;
          Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
            ~effect_disposition:Tool_result.Proven_post_effect
            ~message:"The report was published, but its result manifest could not be stored. Open revision_url or read the recorded artifact; do not publish it again."
            data
          |> Keeper_tool_execution.with_retained_artifacts [revision.body])
    | Error (Published_artifact_store.Invalid message) -> fail Tool_result.Policy_rejection message
    | Error (Published_artifact_store.Missing as error)
    | Error (Published_artifact_store.Conflict _ as error) ->
      fail Tool_result.Workflow_rejection (Published_artifact_store.error_message error)
    | Error (Published_artifact_store.Unavailable _ as error) ->
      fail Tool_result.Runtime_failure (Published_artifact_store.error_message error)
    | Error (Published_artifact_store.Commit_uncertain { id; revision; message }) ->
      let recovery = "Read this artifact revision before retrying publication; the write may have committed." in
      Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown
        ~message:(message ^ ". " ^ recovery)
        (`Assoc ["error", `String "commit_uncertain";
                 "id", `String id; "revision", `Int revision;
                 "url", `String (Published_artifact.url ~revision id);
                 "recovery", `String recovery])

let handle = handle_with_manifest
    ~persist_manifest:(Tool_bridge.attach_artifact_manifest ~projection:Tool_output.Inline_with_reference)

module For_testing = struct
  let handle_with_manifest = handle_with_manifest
end
