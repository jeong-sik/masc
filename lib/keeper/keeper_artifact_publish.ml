let fail class_ message = Keeper_tool_execution.failure ~class_ message

let handle ~base_path ~author ~args =
  match Published_artifact.request_of_json args with
  | Error message -> fail Tool_result.Policy_rejection message
  | Ok request ->
    match Published_artifact_store.publish ~base_path ~author request with
    | Ok (artifact, revision) ->
      Keeper_tool_execution.success_data
        (Published_artifact.publication_to_json ~id:artifact.id revision)
      |> Keeper_tool_execution.with_retained_artifacts [revision.body]
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
