type read_error = Ambiguous_instance | Instance_mismatch | Scope_changed

let instance_id (scope : Mcp_server.workspace_scope) =
  Build_identity.runtime_instance_id ^ "."
  ^ Mcp_server.Workspace_scope_epoch.to_string scope.epoch
;;

let read_if_current ~state ~expected_instances ~read =
  let scope = Mcp_server.workspace_scope state in
  let instance = instance_id scope in
  match expected_instances with
  | _ :: _ :: _ -> Error Ambiguous_instance
  | [expected] when not (String.equal expected instance) -> Error Instance_mismatch
  | [] | [_] ->
    let value = read scope.config in
    if Mcp_server.Workspace_scope_epoch.equal scope.epoch
         (Mcp_server.workspace_scope state).epoch
    then Ok (instance, value)
    else Error Scope_changed
;;
