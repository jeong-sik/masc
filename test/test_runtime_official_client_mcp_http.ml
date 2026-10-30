open Alcotest

type response =
  { status : int
  ; body : string
  }

let config_fields bridge =
  let open Yojson.Safe.Util in
  let config = Runtime_official_client_mcp_http.mcp_config_json bridge ~eager_tools:[] in
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
  let image_data = Base64.encode_string "exact MCP image fixture bytes" in
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
          ; content_blocks = Some
              [ Llm_provider.Types.Text "MASC_TOOL_OK"
              ; Llm_provider.Types.Image { media_type="image/png"; source = Llm_provider.Types.Base64 image_data } ]
          }
      ; stop = None; after_response_sent =
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
      ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
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
  let content = Yojson.Safe.from_string called.body |> member "result" |> member "content"
    |> Yojson.Safe.Util.to_list in
  check int "MCP returns text and image" 2 (List.length content);
  let image = List.nth content 1 in
  check string "MCP image kind" "image" (member "type" image |> Yojson.Safe.Util.to_string);
  check string "MCP image media type" "image/png" (member "mimeType" image |> Yojson.Safe.Util.to_string);
  check string "MCP image bytes survive HTTP bridge" image_data (member "data" image |> Yojson.Safe.Util.to_string);
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

let test_physical_response_observer_with_reused_string_id () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn env#clock 5.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let cases = [|
    "first original", None, true;
    "invalid\255", Some [Llm_provider.Types.Text "invalid\255"], false;
    "image fallback", Some [Llm_provider.Types.Image
      {media_type="image/tiff"; source = Llm_provider.Types.Base64 "AAAA"}], false;
    "second original", None, true |] in
  let completions = Array.init (Array.length cases) (fun _ -> Eio.Promise.create ()) in
  let next = ref 0 in
  let delivered = ref [] and call_ids = ref [] in
  let call_tool ~name:_ ~call_id ~arguments:_ =
    let index = !next in
    incr next;
    call_ids := call_id :: !call_ids;
    let content, content_blocks, _ = cases.(index) in
    let result : Runtime_official_client_tool.dynamic_tool_result =
      {success=true; content; content_blocks; abort_turn=None;
       on_response_sent=Some (fun () -> delivered := index :: !delivered)} in
    let observer = Runtime_official_client_tool.response_observer Mcp result in
    Some { Runtime_official_client_mcp_http.outcome =
      {success=result.success; content=result.content; content_blocks=result.content_blocks};
      stop=None;after_response_sent=(fun () ->
        Runtime_official_client_tool.notify_response_sent observer;
        Eio.Promise.resolve (snd completions.(index)) ()) } in
  let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
    ~secure_random:env#secure_random ~server_name:"masc"
    ~tool_specs:(fun () -> []) ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
    ~call_tool () in
  let endpoint, authorization = config_fields bridge in
  let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
  Array.iteri (fun index (_, _, expected_delivery) ->
    let body = Yojson.Safe.to_string (`Assoc [
      "jsonrpc", `String "2.0"; "id", `String "same";
      "method", `String "tools/call";
      "params", `Assoc ["name", `String "probe"; "arguments", `Assoc []]]) in
    let response = request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization body in
    check int "physical HTTP response completed" 200 response.status;
    Eio.Promise.await (fst completions.(index));
    check bool "only the original projectable result is observed" expected_delivery
      (List.mem index !delivered)) cases;
  check (list int) "separate physical responses retain their own closures" [0;3]
    (List.rev !delivered);
  check (list string) "all client request IDs were deliberately reused"
    ["same";"same";"same";"same"] (List.rev !call_ids)
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
      ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
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
      ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
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

let test_unsupported_media_is_a_delivery_error () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
    ~secure_random:env#secure_random ~server_name:"masc"
    ~tool_specs:(fun () -> [`Assoc ["name", `String "artifact"]])
    ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
    ~call_tool:(fun ~name:_ ~call_id:_ ~arguments:_ -> Some
      { Runtime_official_client_mcp_http.outcome =
          { Runtime_official_client_mcp.success = true
          ; content = "persisted artifact receipt"
          ; content_blocks = Some [Llm_provider.Types.Document
              {media_type="application/pdf"; source = Llm_provider.Types.Base64 "Zml4dHVyZQ=="}]
          }
      ; stop = None; after_response_sent = (fun () -> ()) }) () in
  let endpoint, authorization = config_fields bridge in
  let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
  let response = request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization
    (json_request 2 "tools/call" (`Assoc ["name",`String "artifact";"arguments",`Assoc []])) in
  check int "delivery error remains an MCP tool result" 200 response.status;
  let result = Yojson.Safe.from_string response.body |> member "result" in
  check bool "unsupported media never reports text-only success" true
    (member "isError" result = `Bool true);
  let content = member "content" result |> Yojson.Safe.Util.to_list in
  check (list string) "delivery failure retains prior artifact receipt"
    ["official-client tool result cannot deliver document content";"persisted artifact receipt"]
    (List.map (fun item -> member "text" item |> Yojson.Safe.Util.to_string) content)
;;

exception Stop_turn

let test_turn_cancel_reaches_active_tool_and_releases_dispatch () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun outer ->
  let ready, publish = Eio.Promise.create () in
  let entered, mark_entered = Eio.Promise.create () in
  let cancelled, mark_cancelled = Eio.Promise.create () in
  let release, unblock = Eio.Promise.create () in
  let settled, mark_settled = Eio.Promise.create () in
  Eio.Fiber.fork ~sw:outer (fun () ->
    (try Eio.Switch.run (fun turn ->
      let bridge = Runtime_official_client_mcp_http.start ~sw:turn ~net:env#net
        ~secure_random:env#secure_random ~server_name:"masc"
        ~tool_specs:(fun () -> [`Assoc ["name", `String "wait"]])
        ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
    ~call_tool:(fun ~name:_ ~call_id:_ ~arguments:_ ->
          Eio.Promise.resolve mark_entered ();
          (try Eio.Promise.await release
           with Eio.Cancel.Cancelled _ as exn ->
             Eio.Promise.resolve mark_cancelled ();
             raise exn);
          Some { Runtime_official_client_mcp_http.outcome =
              { Runtime_official_client_mcp.success = true; content = "released"; content_blocks = None }
            ; stop = None; after_response_sent = (fun () -> ()) }) () in
      Eio.Promise.resolve publish (bridge, turn);
      Eio.Fiber.await_cancel ())
     with Stop_turn -> ());
    Eio.Promise.resolve mark_settled ());
  let bridge, turn = Eio.Promise.await ready in
  let endpoint, authorization = config_fields bridge in
  let protocol_version = initialize_session ~sw:outer ~net:env#net ~endpoint ~authorization in
  let request_finished, finish_request = Eio.Promise.create () in
  Eio.Fiber.fork ~sw:outer (fun () ->
    (try ignore (request ~protocol_version ~sw:outer ~net:env#net ~endpoint ~authorization
      (json_request 7 "tools/call" (`Assoc ["name", `String "wait"; "arguments", `Assoc []])))
     with End_of_file | Eio.Io _ -> ());
    Eio.Promise.resolve finish_request ());
  Eio.Promise.await entered;
  Eio.Switch.fail turn Stop_turn;
  (* The test's fallback releases the callback even on the broken protected
     path, so a regression fails finitely instead of hanging switch teardown. *)
  let reached_tool = Eio.Fiber.first
    (fun () -> Eio.Promise.await cancelled; true)
    (fun () -> Eio.Time.sleep env#clock 2.0; false) in
  Eio.Promise.resolve unblock ();
  Eio.Promise.await settled;
  Eio.Promise.await request_finished;
  check bool "turn cancellation reaches the yielding tool callback" true reached_tool;
  let snapshot = Runtime_official_client_mcp_http.For_testing.snapshot bridge in
  check int "cancelled tool has no completed-call observation" 0 snapshot.tool_calls;
  check bool "cancellation does not poison session observation" true
    (snapshot.phase = Runtime_official_client_mcp.Ready)
;;

(* Claude Code is the client behind this transport, and its initial-image path
   ([Runtime_claude_code.validate_images]) refuses anything outside the shared
   set before it spawns. MCP's own ImageContent leaves the set open, so without
   the same gate here a tool result reached the provider in a format the turn
   path had already rejected -- and only after the tool had run. *)
let test_image_media_type_outside_the_shared_set_is_refused ?(media_type="image/svg+xml") ?(data="PHN2Zz48L3N2Zz4=") ?(receipt="diagram receipt") ?(expected=["image/svg+xml";"image/png"]) () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
    ~secure_random:env#secure_random ~server_name:"masc"
    ~tool_specs:(fun () -> [`Assoc ["name", `String "diagram"]])
    ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
    ~call_tool:(fun ~name:_ ~call_id:_ ~arguments:_ -> Some
      { Runtime_official_client_mcp_http.outcome =
          { Runtime_official_client_mcp.success = true
          ; content = receipt
          ; content_blocks = Some [Llm_provider.Types.Image
              {media_type; source = Llm_provider.Types.Base64 data}]
          }
      ; stop = None; after_response_sent = (fun () -> ()) }) () in
  let endpoint, authorization = config_fields bridge in
  let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
  let response = request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization
    (json_request 2 "tools/call" (`Assoc ["name",`String "diagram";"arguments",`Assoc []])) in
  check string "delivery-error response remains valid UTF-8 JSON"
    (Llm_provider.Utf8_sanitize.sanitize response.body) response.body;
  let result = Yojson.Safe.from_string response.body |> member "result" in
  check bool "a media type the client refuses never reports success" true
    (member "isError" result = `Bool true);
  let content = member "content" result |> Yojson.Safe.Util.to_list
    |> List.map (fun item -> member "text" item |> Yojson.Safe.Util.to_string) in
  check bool "the refusal names the media type and keeps the receipt" true
    (match content with
     | [detail; delivered_receipt] ->
       List.for_all (String_util.contains_substring detail) expected
       && delivered_receipt = Llm_provider.Utf8_sanitize.sanitize receipt
     | _ -> false)
;;

(* [Api_common.content_block_to_json] sanitizes every Text it serializes. This
   transport writes its own JSON, so without the same call a tool could put
   invalid UTF-8 on the wire and the client would reject the message after the
   tool had already run. *)
let test_structured_text_is_sanitized_before_it_reaches_the_client () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let raw = "before \xC3\x28 after" in
  let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
    ~secure_random:env#secure_random ~server_name:"masc"
    ~tool_specs:(fun () -> [`Assoc ["name", `String "note"]])
    ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
    ~call_tool:(fun ~name:_ ~call_id:_ ~arguments:_ -> Some
      { Runtime_official_client_mcp_http.outcome =
          { Runtime_official_client_mcp.success = true
          ; content = "note receipt"
          ; content_blocks = Some [Llm_provider.Types.Text raw]
          }
      ; stop = None; after_response_sent = (fun () -> ()) }) () in
  let endpoint, authorization = config_fields bridge in
  let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
  let response = request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization
    (json_request 2 "tools/call" (`Assoc ["name",`String "note";"arguments",`Assoc []])) in
  let result = Yojson.Safe.from_string response.body |> member "result" in
  check bool "a structured text result still succeeds" true
    (member "isError" result <> `Bool true);
  let content = member "content" result |> Yojson.Safe.Util.to_list
    |> List.map (fun item -> member "text" item |> Yojson.Safe.Util.to_string) in
  check (list string) "the client receives what the canonical serializer would write"
    [Llm_provider.Utf8_sanitize.sanitize raw] content
;;

(* A tool the config does not declare eager is listed to the model by name
   only, and the schema file it is told to read sits behind a masc home's
   read_file deny. Every name passed in comes back declared eager, and a
   name not passed is not declared. *)
let test_config_declares_the_given_tools_eager () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let bridge =
    Runtime_official_client_mcp_http.start
      ~sw
      ~net:env#net
      ~secure_random:env#secure_random
      ~server_name:"masc"
      ~tool_specs:(fun () -> [])
      ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Serial)
    ~call_tool:(fun ~name:_ ~call_id:_ ~arguments:_ -> None)
      ()
  in
  let open Yojson.Safe.Util in
  let tools =
    Runtime_official_client_mcp_http.mcp_config_json
      bridge
      ~eager_tools:[ "masc_ask"; "Read" ]
    |> member "mcpServers"
    |> member "masc"
    |> member "tools"
  in
  check (list string) "one entry per given tool" [ "masc_ask"; "Read" ] (keys tools);
  List.iter
    (fun name ->
      check bool (name ^ " is eager") true (tools |> member name |> member "eager" |> to_bool))
    [ "masc_ask"; "Read" ];
  check bool "a tool not given is not declared" true (tools |> member "Execute" = `Null)
;;

let test_independent_tool_can_complete_while_another_is_blocked () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio.Time.with_timeout_exn env#clock 10.0 (fun () ->
    let started, signal_started = Eio.Promise.create () in
    let release, finish = Eio.Promise.create () in
    let first_done, signal_first_done = Eio.Promise.create () in
    let response name = Some {Runtime_official_client_mcp_http.outcome=
      {Runtime_official_client_mcp.success=true;content=name;content_blocks=None};
      stop=None;after_response_sent=(fun () -> ())} in
    let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
      ~secure_random:env#secure_random ~server_name:"masc"
      ~tool_specs:(fun () -> List.map (fun name -> `Assoc ["name",`String name]) ["slow";"independent"])
      ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Concurrent)
      ~call_tool:(fun ~name ~call_id:_ ~arguments:_ ->
        if name="slow" then (Eio.Promise.resolve signal_started ();Eio.Promise.await release);
        response name) () in
    let endpoint, authorization = config_fields bridge in
    let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
    let call id name = request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization
      (json_request id "tools/call" (`Assoc ["name",`String name;"arguments",`Assoc []])) in
    let release () = if Eio.Promise.peek release=None then Eio.Promise.resolve finish () in
    Fun.protect ~finally:release (fun () ->
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_first_done (call 10 "slow"));
      Eio.Promise.await started;
      let fast = call 11 "independent" in
      check int "independent physical HTTP call completes before slow release" 200 fast.status;
      check bool "the original handler is still active" true (Eio.Promise.peek first_done=None);
      let snapshot = Runtime_official_client_mcp_http.For_testing.snapshot bridge in
      check int "snapshot lookup is not blocked by the active handler" 1 snapshot.tool_calls;
      check int "only the real blocked reservation remains retained" 1 snapshot.retained_tool_reservations;
      release ();
      check int "the original call completes after its real release" 200
        (Eio.Promise.await first_done).status;
      check int "completed scheduling history is retired" 0
        (Runtime_official_client_mcp_http.For_testing.snapshot bridge).retained_tool_reservations))
;;

let test_serial_boundary_waits_for_predecessors_and_fences_followers ~fail_serial () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio.Time.with_timeout_exn env#clock 10.0 (fun () ->
    let first_started, signal_first_started = Eio.Promise.create () in
    let serial_reserved, signal_serial_reserved = Eio.Promise.create () in
    let follower_reserved, signal_follower_reserved = Eio.Promise.create () in
    let serial_started, signal_serial_started = Eio.Promise.create () in
    let release_first, finish_first = Eio.Promise.create () in
    let release_serial, finish_serial = Eio.Promise.create () in
    let events = ref [] in
    let record event = events := !events @ [event] in
    let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
      ~secure_random:env#secure_random ~server_name:"masc"
      ~tool_specs:(fun () -> List.map (fun name -> `Assoc ["name",`String name]) ["first";"serial";"follower"])
      ~tool_execution_mode:(fun ~name ~arguments:_ ->
        match name with
        | "serial" -> Eio.Promise.resolve signal_serial_reserved ();Some Agent_core.Tool_contract.Serial
        | "follower" -> Eio.Promise.resolve signal_follower_reserved ();Some Concurrent
        | "first" -> Some Concurrent
        | _ -> None)
      ~call_tool:(fun ~name ~call_id:_ ~arguments:_ ->
        record (name ^ " entered");
        (match name with
         | "first" -> Eio.Promise.resolve signal_first_started ();Eio.Promise.await release_first
         | "serial" -> Eio.Promise.resolve signal_serial_started ();Eio.Promise.await release_serial
         | "follower" -> ()
         | _ -> fail "unknown test producer");
        record (name ^ " settled");
        if name="serial" && fail_serial then failwith "controlled serial handler failure";
        Some {Runtime_official_client_mcp_http.outcome=
          {Runtime_official_client_mcp.success=true;content=name;content_blocks=None};
          stop=None;after_response_sent=(fun () -> ())}) () in
    let endpoint, authorization = config_fields bridge in
    let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
    let start id name =
      let done_, finish = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finish
        (request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization
          (json_request id "tools/call" (`Assoc ["name",`String name;"arguments",`Assoc []]))));
      done_ in
    let release promise resolver = if Eio.Promise.peek promise=None then Eio.Promise.resolve resolver () in
    Fun.protect ~finally:(fun () -> release release_first finish_first;release release_serial finish_serial)
      (fun () ->
        let first = start 20 "first" in
        Eio.Promise.await first_started;
        let serial = start 21 "serial" in
        Eio.Promise.await serial_reserved;
        let follower = start 22 "follower" in
        Eio.Promise.await follower_reserved;
        check (list string) "neither queued handler crosses the active predecessor" ["first entered"] !events;
        release release_first finish_first;
        Eio.Promise.await serial_started;
        check (list string) "the concurrent follower still waits for the admitted Serial call"
          ["first entered";"first settled";"serial entered"] !events;
        release release_serial finish_serial;
        check int "first concurrent call settles" 200 (Eio.Promise.await first).status;
        check int "serial settles with its actual outcome" (if fail_serial then 500 else 200)
          (Eio.Promise.await serial).status;
        check int "follower progresses after success or actual handler failure" 200
          (Eio.Promise.await follower).status;
        check int "success and exception cleanup retire the entire settled frontier" 0
          (Runtime_official_client_mcp_http.For_testing.snapshot bridge).retained_tool_reservations;
        check (list string) "original physical order survives the serial effect boundary"
          ["first entered";"first settled";"serial entered";"serial settled";"follower entered";"follower settled"] !events))
;;

let test_absent_producer_contract_cannot_execute_a_tool () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let executed = ref false in
  let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
    ~secure_random:env#secure_random ~server_name:"masc"
    ~tool_specs:(fun () -> []) ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> None)
    ~call_tool:(fun ~name:_ ~call_id:_ ~arguments:_ -> executed:=true;None) () in
  let endpoint, authorization = config_fields bridge in
  let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
  let refused = request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization
    (json_request 30 "tools/call" (`Assoc ["name",`String "unregistered";"arguments",`Assoc []])) in
  check int "an unknown frozen producer contract returns a JSON-RPC error over HTTP" 200 refused.status;
  let json = Yojson.Safe.from_string refused.body in
  check int "the parsed JSON-RPC error reports an unknown tool" (-32602)
    Yojson.Safe.Util.(json |> member "error" |> member "code" |> to_int);
  check bool "the effect-capable handler is never entered" false !executed
;;

let test_host_stop_drains_admitted_peers_and_refuses_late_execution ~peer_fails () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio.Time.with_timeout_exn env#clock 10.0 (fun () ->
    let peer_started, signal_peer_started = Eio.Promise.create () in
    let release_peer, finish_peer = Eio.Promise.create () in
    let peer_done, signal_peer_done = Eio.Promise.create () in
    let stopped, signal_stopped = Eio.Promise.create () in
    let peer_calls = ref 0 and stop_calls = ref 0 and late_calls = ref 0 in
    let deferred : Runtime_official_client_tool.host_stop =
      Terminal_tool_boundary {tool_name="stop";outcome=Durable_stimulus_deferred} in
    let failed : Runtime_official_client_tool.host_stop =
      Terminal_tool_boundary {tool_name="peer";outcome=Terminal_failed
        {failure_class=Tool_result.Runtime_failure;effect_disposition=Tool_result.Effect_outcome_unknown;
         detail=Keeper_terminal_effect_detail.Tool_failed {internal_tool_name="peer";message="original peer failure"}}} in
    let bridge = Runtime_official_client_mcp_http.start ~sw ~net:env#net
      ~secure_random:env#secure_random ~server_name:"masc"
      ~tool_specs:(fun () -> List.map (fun name -> `Assoc ["name",`String name]) ["peer";"stop";"late"])
      ~tool_execution_mode:(fun ~name:_ ~arguments:_ -> Some Agent_core.Tool_contract.Concurrent)
      ~call_tool:(fun ~name ~call_id:_ ~arguments:_ ->
        let stop = match name with
          | "peer" -> incr peer_calls;Eio.Promise.resolve signal_peer_started ();
            Eio.Promise.await release_peer;if peer_fails then Some failed else None
          | "stop" -> incr stop_calls;Some deferred
          | "late" -> incr late_calls;None
          | _ -> fail "unknown producer" in
        Some {Runtime_official_client_mcp_http.outcome=
          {Runtime_official_client_mcp.success=(not (name="peer" && peer_fails));
           content="original " ^ name;content_blocks=None};stop;
          after_response_sent=(fun () -> ())}) () in
    let endpoint, authorization = config_fields bridge in
    let protocol_version = initialize_session ~sw ~net:env#net ~endpoint ~authorization in
    let call id name = request ~protocol_version ~sw ~net:env#net ~endpoint ~authorization
      (json_request id "tools/call" (`Assoc ["name",`String name;"arguments",`Assoc []])) in
    let release () = if Eio.Promise.peek release_peer=None then Eio.Promise.resolve finish_peer () in
    Fun.protect ~finally:release (fun () ->
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_peer_done (call 40 "peer"));
      Eio.Promise.await peer_started;
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_stopped
        (Runtime_official_client_mcp_http.await_host_stop bridge));
      check int "the stopping physical response is returned" 200 (call 41 "stop").status;
      check bool "host stop cannot cancel its still-running admitted peer" true
        (Eio.Promise.peek stopped=None);
      let late = call 42 "late" in
      check int "closed admission returns an explicit result" 200 late.status;
      let json = Yojson.Safe.from_string late.body in
      check bool "the late call reports no successful execution" true
        ((json |> member "result" |> member "isError") = `Bool true);
      check int "a late request never enters its effect-capable handler" 0 !late_calls;
      check bool "the late refusal does not release the earlier peer" true
        (Eio.Promise.peek stopped=None);
      release ();
      check int "the admitted peer returns its actual result before scope stop" 200
        (Eio.Promise.await peer_done).status;
      let actual = Eio.Promise.await stopped in
      check bool "a later authoritative peer failure outranks the earlier scheduling stop" true
        (actual = if peer_fails then failed else deferred);
      check int "original peer executes once" 1 !peer_calls;
      check int "original stop tool executes once" 1 !stop_calls;
      check int "stop drain retains no completed reservation history" 0
        (Runtime_official_client_mcp_http.For_testing.snapshot bridge).retained_tool_reservations))
;;

let () =
  run
    "runtime_official_client_mcp_http"
    [ ( "turn-scoped transport"
      , [ test_case
            "capability, protocol, phase, and tool callback"
            `Quick
            test_turn_scoped_capability_and_protocol
        ; test_case "unsupported media is an explicit delivery error" `Quick
            test_unsupported_media_is_a_delivery_error
        ; test_case "image media type outside the shared set is refused" `Quick
            (fun () -> test_image_media_type_outside_the_shared_set_is_refused ())
        ; test_case "malformed Base64 tool image preserves explicit failure and receipt" `Quick
            (fun () -> test_image_media_type_outside_the_shared_set_is_refused
              ~media_type:"image/png" ~data:"%%%" ~expected:["valid Base64"] ())
        ; test_case "image delivery failure sanitizes the retained receipt on the wire" `Quick
            (fun () -> test_image_media_type_outside_the_shared_set_is_refused
              ~media_type:"image/png" ~data:"%%%" ~receipt:"before \xC3\x28 after"
              ~expected:["valid Base64"] ())
        ; test_case "structured text is sanitized before it reaches the client"
            `Quick test_structured_text_is_sanitized_before_it_reaches_the_client
        ; test_case "the config declares the given tools eager" `Quick
            test_config_declares_the_given_tools_eager
        ] )
    ; ( "response delivery"
      , [ test_case "reused string ID keeps physical delivery and substitution separate"
            `Quick test_physical_response_observer_with_reused_string_id ] )
    ; ( "tool scheduling"
      , [ test_case "independent HTTP tool completes while a peer is blocked" `Quick
            test_independent_tool_can_complete_while_another_is_blocked
        ; test_case "Serial success waits for predecessors and fences followers" `Quick
            (test_serial_boundary_waits_for_predecessors_and_fences_followers ~fail_serial:false)
        ; test_case "Serial failure waits for predecessors and releases followers" `Quick
            (test_serial_boundary_waits_for_predecessors_and_fences_followers ~fail_serial:true)
        ; test_case "absent producer contract cannot execute a tool" `Quick
            test_absent_producer_contract_cannot_execute_a_tool
        ; test_case "host stop drains admitted peer and refuses late execution" `Quick
            (test_host_stop_drains_admitted_peers_and_refuses_late_execution ~peer_fails:false)
        ; test_case "later peer failure outranks host stop after admitted drain" `Quick
            (test_host_stop_drains_admitted_peers_and_refuses_late_execution ~peer_fails:true)
        ] )
    ; ( "effect boundary"
      , [ test_case "turn cancellation reaches active callback without poisoning dispatch" `Quick
            test_turn_cancel_reaches_active_tool_and_releases_dispatch
        ; test_case
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
