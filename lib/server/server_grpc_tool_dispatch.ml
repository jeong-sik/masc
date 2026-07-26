(* TEL-OK: pure fail-closed JSON shape gate. Its sole production callback is
   [Mcp_server_eio_execute.execute_tool_eio], which owns request, audit, and
   tool-span telemetry; rejected input performs no tool action. *)
let dispatch ~dispatch arguments_json =
  match Yojson.Safe.from_string arguments_json with
  | (`Assoc _ as arguments) -> dispatch arguments
  | _ -> Error "Invalid params: expected object"
  | exception Yojson.Json_error _ -> Error "Invalid params: expected object"
;;
