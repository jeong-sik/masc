(* TEL-OK: pure fail-closed JSON shape gate. Its sole production callback is
   [Mcp_server_eio_execute.execute_tool_eio], which owns request, audit, and
   tool-span telemetry; rejected input performs no tool action. *)
let dispatch ~dispatch arguments_json
  : (_, Masc_grpc_types.tool_dispatch_error) result
  =
  let parsed =
    if String.equal arguments_json ""
    then Ok (`Assoc [])
    else
      match Yojson.Safe.from_string arguments_json with
      | (`Assoc _ as arguments) -> Ok arguments
      | _ -> Error ()
      | exception Yojson.Json_error _ -> Error ()
  in
  match parsed with
  | Error () ->
    Error
      { Masc_grpc_types.code = Masc.Mcp_error_code.Invalid_params
      ; message = "Invalid params: expected object"
      }
  | Ok arguments ->
    (match dispatch arguments with
     | Ok _ as result -> result
     | Error message ->
       Error
         { Masc_grpc_types.code = Masc.Mcp_error_code.Internal_error; message })
;;
