let json ?code ?(fields = []) sentence =
  let code_field =
    match code with
    | None -> []
    | Some code -> [ ("code", `String code) ]
  in
  `Assoc ((("error", `String sentence) :: code_field) @ fields)

let expected_workspace_error error =
  let status, code =
    match error with
    | Workspace.Invalid_workspace_precondition ->
      `Bad_request, "invalid_workspace_precondition"
    | Workspace.Workspace_precondition_failed ->
      `Conflict, "workspace_precondition_failed"
  in
  status, json ~code (Workspace.expected_workspace_error_message error)
