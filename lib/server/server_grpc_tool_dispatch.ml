(* TEL-OK: pure fail-closed JSON shape gate. Its sole production callback is
   [Mcp_server_eio_execute.execute_tool_eio], which owns request, audit, and
   tool-span telemetry; rejected input performs no tool action. *)
type error =
  { code : Mcp_error_code.t
  ; message : string
  }

let error_code error = error.code
let error_message error = error.message

let dispatch ~dispatch arguments_json =
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
      { code = Mcp_error_code.Invalid_params
      ; message = "Invalid params: expected object"
      }
  | Ok arguments ->
    (match dispatch arguments with
     | Ok _ as result -> result
     | Error message ->
       Error { code = Mcp_error_code.Internal_error; message })
;;
