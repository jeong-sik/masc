type read_error = Ambiguous_instance | Instance_mismatch | Scope_changed

let instance_id (scope : Mcp_server.workspace_scope) =
  Build_identity.runtime_instance_id ^ "."
  ^ Mcp_server.Workspace_scope_epoch.to_string scope.epoch
;;

type stream_owner = {
  state : Mcp_server.server_state;
  scope : Mcp_server.workspace_scope;
  instance : string;
}

type stream_admission_error =
  | Instance_required
  | Instance_ambiguous
  | Instance_changed

let stream_config owner = owner.scope.config
let stream_instance owner = owner.instance
let stream_is_current owner =
  Mcp_server.Workspace_scope_epoch.equal owner.scope.epoch
    (Mcp_server.workspace_scope owner.state).epoch
;;

let await_stream_replaced owner =
  Eio.Promise.await (Mcp_server.workspace_scope_replaced owner.scope)
;;

let admit_stream ~state (request : Httpun.Request.t) =
  let scope = Mcp_server.workspace_scope state in
  let instance = instance_id scope in
  match Httpun.Headers.get_multi request.headers Sse_wire.instance_header with
  | [] -> Error Instance_required
  | _ :: _ :: _ -> Error Instance_ambiguous
  | [expected] ->
      let owner = { state; scope; instance } in
      if String.equal expected instance && stream_is_current owner
      then Ok owner else Error Instance_changed
;;

let refuse_stream error reqd =
  let status, code, detail = match error with
    | Instance_required -> `Bad_request, "observer_instance_required",
        "A native query requires its original observer instance"
    | Instance_ambiguous -> `Bad_request, "observer_instance_ambiguous",
        "The observer instance must occur exactly once"
    | Instance_changed -> `Conflict, "observer_instance_changed",
        "The original observer workspace has been replaced" in
  Http_server_eio.Response.json_value ~status
    (`Assoc ["error", `String detail; "code", `String code]) reqd
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
