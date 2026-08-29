(* See keeper_tool_webmcp.mli. *)

(* Names live in config/tools/keeper_webmcp_{list,call}.toml and reach here
   through the schemas, so the tools cannot answer to names the definitions
   do not declare. *)
let list_tool_name = (Tool_schemas_webmcp.list_schema : Masc_domain.tool_schema).name
let call_tool_name = (Tool_schemas_webmcp.call_schema : Masc_domain.tool_schema).name

let ok ~tool_name ~start_time data =
  Tool_result.make_ok ~tool_name ~start_time ~data ()
;;

let refusal ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let dependency_unavailable ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Dependency_unavailable
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let runtime_failure ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let required_string args key =
  match Json_util.get_string args key with
  | Some value ->
    (match String_util.trim_nonempty value with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s must not be blank" key))
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let optional_cdp_port args =
  match Json_util.get_int args "cdp_port" with
  | None -> Ok None
  | Some port when port >= 1 && port <= 65535 -> Ok (Some port)
  | Some port -> Error (Printf.sprintf "cdp_port must be within 1..65535, got %d" port)
;;

(* A bridge failure splits on who can fix it: a missing page/surface/tool or
   bad arguments is the caller's precondition (deterministic refusal); a
   missing node binary, a dead CDP endpoint, or a timeout is an unavailable
   dependency; only non-JSON output from our own bridge is an internal bug. *)
let result_of_bridge ~tool_name ~start_time outcome =
  match outcome with
  | Ok stdout ->
    (match Yojson.Safe.from_string stdout with
     | json -> ok ~tool_name ~start_time json
     | exception Yojson.Json_error message ->
       runtime_failure
         ~tool_name
         ~start_time
         (Printf.sprintf "bridge returned non-JSON output: %s" message))
  | Error failure ->
    let message = Webmcp_bridge.failure_message failure in
    (match failure with
     | Webmcp_bridge.Invalid_args _
     | Webmcp_bridge.Page_not_found _
     | Webmcp_bridge.Surface_or_tool_missing _ ->
       refusal ~tool_name ~start_time message
     | Webmcp_bridge.Bridge_unavailable _ | Webmcp_bridge.Bridge_failure _ ->
       dependency_unavailable ~tool_name ~start_time message)
;;

let ( let* ) = Result.bind

let run_list ~args =
  let tool_name = list_tool_name in
  let start_time = Time_compat.now () in
  let prepared =
    let* page = required_string args "page" in
    let* cdp_port = optional_cdp_port args in
    Ok (page, cdp_port)
  in
  match prepared with
  | Error message -> refusal ~tool_name ~start_time message
  | Ok (page, cdp_port) ->
    Webmcp_bridge.list_tools ?cdp_port ~page ()
    |> result_of_bridge ~tool_name ~start_time
;;

let run_call ~args =
  let tool_name = call_tool_name in
  let start_time = Time_compat.now () in
  let prepared =
    let* page = required_string args "page" in
    let* tool = required_string args "tool" in
    let* args_json = required_string args "args_json" in
    let* cdp_port = optional_cdp_port args in
    Ok (page, tool, args_json, cdp_port)
  in
  match prepared with
  | Error message -> refusal ~tool_name ~start_time message
  | Ok (page, tool, args_json, cdp_port) ->
    Webmcp_bridge.call_tool ?cdp_port ~page ~tool ~args_json ()
    |> result_of_bridge ~tool_name ~start_time
;;

let dispatch ~name ~args : Tool_result.result option =
  if String.equal name list_tool_name
  then Some (run_list ~args)
  else if String.equal name call_tool_name
  then Some (run_call ~args)
  else None
;;
