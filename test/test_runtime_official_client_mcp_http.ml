open Alcotest

type response =
  { status : int
  ; body : string
  }

let config_fields bridge =
  let open Yojson.Safe.Util in
  let config = Runtime_official_client_mcp_http.mcp_config_json bridge in
  let server = config |> member "mcpServers" |> member "masc" in
  let endpoint = server |> member "url" |> to_string in
  let authorization =
    server |> member "headers" |> member "Authorization" |> to_string
  in
  endpoint, authorization
;;

let rec read_headers reader content_length =
  let line = Eio.Buf_read.line reader in
  if String.equal line "\r" || String.equal line ""
  then content_length
  else
    let content_length =
      match String.index_opt line ':' with
      | None -> content_length
      | Some index ->
        let name =
          String.sub line 0 index |> String.trim |> String.lowercase_ascii
        in
        if not (String.equal name "content-length")
        then content_length
        else
          String.sub line (index + 1) (String.length line - index - 1)
          |> String.trim
          |> int_of_string
    in
    read_headers reader content_length
;;

let request ~sw ~net ~endpoint ~authorization body =
  let uri = Uri.of_string endpoint in
  let port = Uri.port uri |> Option.get in
  let path = Uri.path uri in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Flow.copy_string
    (Printf.sprintf
       "POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: %s\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
       path
       port
       authorization
       (String.length body)
       body)
    flow;
  let reader = Eio.Buf_read.of_flow ~max_size:(2 * 1024 * 1024) flow in
  let status_line = Eio.Buf_read.line reader in
  let status =
    match String.split_on_char ' ' status_line with
    | _version :: code :: _ -> int_of_string code
    | _ -> failf "invalid HTTP status line: %S" status_line
  in
  let content_length = read_headers reader 0 in
  { status; body = Eio.Buf_read.take content_length reader }
;;

let json_request id method_ params =
  `Assoc
    [ "jsonrpc", `String "2.0"
    ; "id", `Int id
    ; "method", `String method_
    ; "params", params
    ]
  |> Yojson.Safe.to_string
;;

let member name json = Yojson.Safe.Util.member name json

let test_turn_scoped_capability_and_protocol () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref [] in
  let tool_specs () =
    [ `Assoc
        [ "name", `String "masc_probe"
        ; "description", `String "Return a marker"
        ; "inputSchema", `Assoc [ "type", `String "object" ]
        ]
    ]
  in
  let call_tool ~name ~call_id ~arguments =
    calls := (name, call_id, arguments) :: !calls;
    Some
      { Runtime_official_client_mcp.success = true
      ; content = "MASC_TOOL_OK"
      }
  in
  let bridge =
    Runtime_official_client_mcp_http.start
      ~sw
      ~net:env#net
      ~secure_random:env#secure_random
      ~server_name:"masc"
      ~tool_specs
      ~call_tool
      ()
  in
  let endpoint, authorization = config_fields bridge in
  let initialize =
    json_request
      2
      "initialize"
      (`Assoc
         [ "protocolVersion", `String "2025-11-25"
         ; ( "clientInfo"
           , `Assoc
               [ "name", `String "antigravity-client"
               ; "version", `String "v1.0.0"
               ] )
         ; "capabilities", `Assoc []
         ])
  in
  let unauthorized =
    request
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization:"Bearer wrong"
      initialize
  in
  check int "wrong capability" 401 unauthorized.status;
  let discover =
    request
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 1 "server/discover" (`Assoc []))
  in
  check int "discovery extension is an exact JSON-RPC miss" 200 discover.status;
  check int
    "discovery error"
    (-32601)
    (Yojson.Safe.from_string discover.body
     |> member "error"
     |> member "code"
     |> Yojson.Safe.Util.to_int);
  let initialized =
    request ~sw ~net:env#net ~endpoint ~authorization initialize
  in
  check int "initialize" 200 initialized.status;
  check string
    "negotiated measured protocol"
    "2025-11-25"
    (Yojson.Safe.from_string initialized.body
     |> member "result"
     |> member "protocolVersion"
     |> Yojson.Safe.Util.to_string);
  let call_params =
    `Assoc
      [ "name", `String "masc_probe"
      ; "arguments", `Assoc [ "marker", `String "measured" ]
      ]
  in
  let premature =
    request
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 3 "tools/call" call_params)
  in
  check int "tool call before initialized notification" 409 premature.status;
  check int "premature call not executed" 0 (List.length !calls);
  let notification =
    {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|}
  in
  let notified =
    request ~sw ~net:env#net ~endpoint ~authorization notification
  in
  check int "initialized notification" 202 notified.status;
  let listed =
    request
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 4 "tools/list" (`Assoc []))
  in
  check int "tools/list" 200 listed.status;
  check string
    "turn tool"
    "masc_probe"
    (Yojson.Safe.from_string listed.body
     |> member "result"
     |> member "tools"
     |> Yojson.Safe.Util.to_list
     |> List.hd
     |> member "name"
     |> Yojson.Safe.Util.to_string);
  let called =
    request
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 5 "tools/call" call_params)
  in
  check int "tools/call" 200 called.status;
  check string
    "tool result"
    "MASC_TOOL_OK"
    (Yojson.Safe.from_string called.body
     |> member "result"
     |> member "content"
     |> Yojson.Safe.Util.to_list
     |> List.hd
     |> member "text"
     |> Yojson.Safe.Util.to_string);
  let duplicate_key =
    {|{"jsonrpc":"2.0","id":6,"method":"tools/call","method":"tools/call","params":{"name":"masc_probe"}}|}
  in
  let duplicate =
    request
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      duplicate_key
  in
  check int "duplicate JSON key" 400 duplicate.status;
  check int "only admitted call executed" 1 (List.length !calls);
  let snapshot = Runtime_official_client_mcp_http.snapshot bridge in
  check bool
    "ready"
    true
    (snapshot.phase = Runtime_official_client_mcp_http.Ready);
  check int "authenticated requests" 7 snapshot.authenticated_requests;
  check int "rejected requests" 3 snapshot.rejected_requests;
  check int "measured tool calls" 1 snapshot.tool_calls;
  check
    (option string)
    "protocol evidence"
    (Some "2025-11-25")
    snapshot.negotiated_protocol_version
;;

let () =
  run
    "runtime_official_client_mcp_http"
    [ ( "turn-scoped transport"
      , [ test_case
            "capability, protocol, phase, and tool callback"
            `Quick
            test_turn_scoped_capability_and_protocol
        ] )
    ]
;;
