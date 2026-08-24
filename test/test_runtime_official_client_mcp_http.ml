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

let request
      ?(method_ = "POST")
      ?(accept = Some "application/json, text/event-stream")
      ?origin
      ?protocol_version
      ~sw
      ~net
      ~endpoint
      ~authorization
      body
  =
  let uri = Uri.of_string endpoint in
  let port = Uri.port uri |> Option.get in
  let path = Uri.path uri in
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let optional_header name = function
    | None -> []
    | Some value -> [ Printf.sprintf "%s: %s" name value ]
  in
  let headers =
    [ Printf.sprintf "Host: 127.0.0.1:%d" port
    ; "Authorization: " ^ authorization
    ; "Content-Type: application/json"
    ]
    @ optional_header "Accept" accept
    @ optional_header "Origin" origin
    @ optional_header "MCP-Protocol-Version" protocol_version
    @ [ Printf.sprintf "Content-Length: %d" (String.length body)
      ; "Connection: close"
      ]
  in
  Eio.Flow.copy_string
    (Printf.sprintf
       "%s %s HTTP/1.1\r\n%s\r\n\r\n%s"
       method_
       path
       (String.concat "\r\n" headers)
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

let initialize_session ~sw ~net ~endpoint ~authorization =
  let protocol_version = "2025-11-25" in
  let initialize =
    json_request
      1
      "initialize"
      (`Assoc
         [ "protocolVersion", `String protocol_version
         ; ( "clientInfo"
           , `Assoc [ "name", `String "test-client"; "version", `String "1" ] )
         ; "capabilities", `Assoc []
         ])
  in
  let initialized =
    request ~sw ~net ~endpoint ~authorization initialize
  in
  check int "initialize" 200 initialized.status;
  let notified =
    request
      ~protocol_version
      ~sw
      ~net
      ~endpoint
      ~authorization
      {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|}
  in
  check int "initialized notification" 202 notified.status;
  protocol_version
;;

let test_turn_scoped_capability_and_protocol () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let calls = ref [] in
  let responses_sent = ref [] in
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
      { Runtime_official_client_mcp_http.outcome =
          { Runtime_official_client_mcp.success = true
          ; content = "MASC_TOOL_OK"
          }
      ; after_response_sent =
          (fun () -> responses_sent := call_id :: !responses_sent)
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
  let protocol_version = "2025-11-25" in
  let initialize =
    json_request
      2
      "initialize"
      (`Assoc
         [ "protocolVersion", `String protocol_version
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
  let cross_origin =
    request
      ~origin:"https://attacker.example"
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      initialize
  in
  check int "explicit browser origin" 403 cross_origin.status;
  let missing_accept =
    request
      ~accept:None
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      initialize
  in
  check int "streamable Accept is required" 406 missing_accept.status;
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
    protocol_version
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
  let missing_protocol_header =
    request
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 3 "tools/call" call_params)
  in
  check int "subsequent protocol header is required" 400 missing_protocol_header.status;
  let mismatched_protocol_header =
    request
      ~protocol_version:"2024-11-05"
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 3 "tools/call" call_params)
  in
  check int "mismatched protocol header" 400 mismatched_protocol_header.status;
  let premature =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 3 "tools/call" call_params)
  in
  check int "tool call before initialized notification" 400 premature.status;
  check int "premature call not executed" 0 (List.length !calls);
  let notification =
    {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|}
  in
  let notified =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      notification
  in
  check int "initialized notification" 202 notified.status;
  let listed =
    request
      ~protocol_version
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
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 5 "tools/call" call_params)
  in
  check int "tools/call" 200 called.status;
  (* [after_response_sent] runs in the bridge's fiber after the response
     bytes flush, so the client can observe the completed response before
     that fiber is scheduled again. Yield until the hook lands instead of
     asserting a scheduling order the contract never promised (#28485:
     expected ["5"], CI received []). Bounded so a hook that never fires
     still fails here rather than hanging the suite. *)
  let rec await_response_acknowledgement remaining =
    if !responses_sent <> [] || remaining = 0
    then ()
    else (
      Eio.Fiber.yield ();
      await_response_acknowledgement (remaining - 1))
  in
  await_response_acknowledgement 1_000;
  (* The hook fired, and it fired for the call that ran. Spelling the id as
     ["5"] recorded that call_id used to be the JSON-RPC request id, which is
     unique only within one session -- two sessions reused it and every
     consumer joining on it mixed the two executions up (#25034). The
     assertion now says what it means: one acknowledgement, for this call. *)
  let executed_call_id =
    match !calls with
    | (_, call_id, _) :: _ -> call_id
    | [] -> fail "the tool call did not reach the handler"
  in
  check (list string) "response acknowledgement" [ executed_call_id ] !responses_sent;
  check bool
    "the tool-call identity is not the session-scoped request id"
    false
    (String.equal executed_call_id "5");
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
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      duplicate_key
  in
  check int "duplicate JSON key" 400 duplicate.status;
  let deletion =
    request
      ~method_:"DELETE"
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      ""
  in
  check int "unsupported session deletion" 405 deletion.status;
  check int "only admitted call executed" 1 (List.length !calls);
  let snapshot = Runtime_official_client_mcp_http.For_testing.snapshot bridge in
  check bool
    "ready"
    true
    (snapshot.phase = Runtime_official_client_mcp.Ready);
  check int "authenticated requests" 11 snapshot.authenticated_requests;
  check int "rejected requests" 8 snapshot.rejected_requests;
  check int "measured tool calls" 1 snapshot.tool_calls;
  check
    (option string)
    "protocol evidence"
    (Some "2025-11-25")
    snapshot.negotiated_protocol_version
;;

let test_callback_failures_do_not_poison_protocol_state () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let effects = ref 0 in
  let inventory_fails = ref false in
  let tool_specs () =
    if !inventory_fails
    then failwith "inventory exploded"
    else [ `Assoc [ "name", `String "masc_effect" ] ]
  in
  let call_tool ~name:_ ~call_id:_ ~arguments:_ =
    incr effects;
    failwith "effect applied before callback failure"
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
  let protocol_version =
    initialize_session ~sw ~net:env#net ~endpoint ~authorization
  in
  let call =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request
         2
         "tools/call"
         (`Assoc [ "name", `String "masc_effect"; "arguments", `Assoc [] ]))
  in
  check int "unknown tool outcome is a server failure" 500 call.status;
  check int
    "typed internal JSON-RPC error"
    (-32603)
    (Yojson.Safe.from_string call.body
     |> member "error"
     |> member "code"
     |> Yojson.Safe.Util.to_int);
  check int "effect ran exactly once" 1 !effects;
  inventory_fails := true;
  let unavailable =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 3 "tools/list" (`Assoc []))
  in
  check int "inventory failure is a server failure" 500 unavailable.status;
  inventory_fails := false;
  let recovered =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 4 "tools/list" (`Assoc []))
  in
  check int "callback failure did not poison protocol mutex" 200 recovered.status;
  let snapshot = Runtime_official_client_mcp_http.For_testing.snapshot bridge in
  check bool "session remains ready" true (snapshot.phase = Ready);
  check int "failed effect is not counted as completed" 0 snapshot.tool_calls;
  check int "callback failures are observable rejections" 2 snapshot.rejected_requests
;;

(* An unrecognized notification used to answer HTTP 400, which agy read as a
   dead connection: it sends [notifications/roots/list_changed] right after
   [notifications/initialized] and dropped the session 32ms into every turn,
   removing all advertised tools before the model spoke (masc#28431). The
   session must survive it and keep serving tools. *)
let test_unknown_notification_is_ignored_and_session_survives () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let tool_specs () = [ `Assoc [ "name", `String "masc_probe" ] ] in
  (* This test never reaches tools/call; the callback exists to satisfy [start]. *)
  let call_tool ~name:_ ~call_id:_ ~arguments:_ = None in
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
  let protocol_version =
    initialize_session ~sw ~net:env#net ~endpoint ~authorization
  in
  let roots_changed =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      {|{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}|}
  in
  check int "unknown notification is accepted" 202 roots_changed.status;
  check string "notification draws no body" "" (String.trim roots_changed.body);
  let listed =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 4 "tools/list" (`Assoc []))
  in
  check int "session survives the notification" 200 listed.status;
  let snapshot = Runtime_official_client_mcp_http.For_testing.snapshot bridge in
  check bool "phase is still ready" true (snapshot.phase = Ready);
  (* An unrecognized *request* carries an id and still owes a JSON-RPC error. *)
  let unknown_request =
    request
      ~protocol_version
      ~sw
      ~net:env#net
      ~endpoint
      ~authorization
      (json_request 5 "resources/list" (`Assoc []))
  in
  check int "unknown request still answers" 200 unknown_request.status;
  check int
    "unknown request answers method-not-found"
    (-32601)
    (Yojson.Safe.from_string unknown_request.body
     |> member "error"
     |> member "code"
     |> Yojson.Safe.Util.to_int)
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
    ; ( "effect boundary"
      , [ test_case
            "callback failures remain typed and do not poison lifecycle"
            `Quick
            test_callback_failures_do_not_poison_protocol_state
        ] )
    ; ( "notifications"
      , [ test_case
            "unknown notification is ignored and the session survives"
            `Quick
            test_unknown_notification_is_ignored_and_session_survives
        ] )
    ]
;;
