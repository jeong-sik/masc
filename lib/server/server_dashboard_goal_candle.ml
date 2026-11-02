let generation_headers =
  [ "x-masc-runtime-instance-id", Build_identity.runtime_instance_id
  ; "x-masc-execution-publication-epoch", Server_dashboard_http_execution_surfaces.execution_publication_epoch ]

let response ~config request =
  match Server_auth.validate_read_workspace_precondition ~config request with
  | Error error ->
    let json, status = Server_auth.read_workspace_precondition_error_response error in
    (status, json)
  | Ok Server_auth.Workspace_read_unbound ->
    let json, status =
      Server_auth.read_workspace_precondition_error_response Workspace.Invalid_workspace_precondition in
    (status, json)
  | Ok Server_auth.Workspace_read_matched ->
    let goal_fields = Uri.query (Uri.of_string request.Httpun.Request.target)
      |> List.filter (fun (key, _) -> String.equal key "goal_id") in
    (match goal_fields with
     | [(_, [raw])] when String.trim raw <> "" ->
       let goal_id = String.trim raw in
       let json = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
         Candle_goal_observation_reader.read ~base_path:config.Workspace.base_path ~goal_id
         |> Candle_goal_observation.to_yojson ~goal_id) in
       (`OK, json)
     | _ ->
       (`Bad_request, `Assoc ["error", `String "goal_id must occur once and be nonempty"]))
;;
