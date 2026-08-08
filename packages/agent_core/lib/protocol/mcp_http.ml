open Result_syntax
module Sdk_http_client = Mcp_protocol_http.Http_client

type config =
  { base_url : string
  ; headers : (string * string) list
  }

type t = { client : Sdk_http_client.t }

let http_transport_error ~url exn =
  Error.Mcp (HttpTransportFailed { url; detail = Printexc.to_string exn })
;;

let connect ~sw ~net config =
  try
    Ok
      { client =
          Sdk_http_client.create
            ~endpoint:config.base_url
            ~headers:config.headers
            ~net
            ~sw
            ()
      }
  with
  | Eio.Io _ as exn -> Error (http_transport_error ~url:config.base_url exn)
  | Unix.Unix_error _ as exn -> Error (http_transport_error ~url:config.base_url exn)
  | Failure msg ->
    Error (Error.Mcp (HttpTransportFailed { url = config.base_url; detail = msg }))
;;

let initialize t =
  match
    Sdk_http_client.initialize t.client ~client_name:"oas-sdk" ~client_version:"0.87.1"
  with
  | Ok _ -> Ok ()
  | Error detail -> Error (Error.Mcp (InitializeFailed { detail }))
;;

let list_tools t =
  match Sdk_http_client.list_tools_all t.client with
  | Error detail -> Error (Error.Mcp (ToolListFailed { detail }))
  | Ok tools -> Ok (List.map Mcp.mcp_tool_of_sdk_tool tools)
;;

let call_tool t ~name ~arguments =
  match Sdk_http_client.call_tool t.client ~name ~arguments () with
  | Error detail ->
    Error
      { Types.message = Printf.sprintf "MCP tools/call '%s' failed: %s" name detail
      ; recoverable = true
      ; error_class = None
      }
  | Ok result ->
    let content = Mcp.text_of_tool_result result in
    if Option.value ~default:false result.Mcp_schema.Sdk_types.is_error
    then Error { Types.message = content; recoverable = true; error_class = None }
    else Ok { Types.content; _meta = None }
;;

let close t = ignore (Sdk_http_client.close t.client)

type http_spec =
  { base_url : string
  ; headers : (string * string) list
  ; name : string
  }

let connect_and_load_managed ~sw ~net (spec : http_spec)
  : (Mcp.managed, Error.sdk_error) result
  =
  let* client = connect ~sw ~net { base_url = spec.base_url; headers = spec.headers } in
  let* () = initialize client in
  let* mcp_tools = list_tools client in
  let* tools =
    List.fold_right
      (fun (mt : Mcp.mcp_tool) acc ->
         let* tools = acc in
         match
           Mcp.mcp_tool_to_sdk_tool_result mt ~call_fn:(fun input ->
             call_tool client ~name:mt.name ~arguments:input)
         with
         | Ok tool_ -> Ok (tool_ :: tools)
         | Error detail ->
           Error (Error.Config (InvalidConfig { field = "mcp.http.tools"; detail })))
      mcp_tools
      (Ok [])
  in
  Ok
    { Mcp.tools
    ; name = spec.name
    ; transport =
        Http
          { close_fn = (fun () -> close client)
          ; base_url = spec.base_url
          ; headers = spec.headers
          }
    }
;;

let connect_and_load ~sw ~net spec = connect_and_load_managed ~sw ~net spec
