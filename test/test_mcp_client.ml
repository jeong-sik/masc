(** What masc sends to somebody else's MCP server, and what it accepts back.

    Every case runs without a server: the transport is an argument, so what
    is pinned is the request this builds and the answers it reads -- which
    is the part a live server could not tell us anything about anyway. *)

let check = Alcotest.check
let str = Alcotest.string

let response ?(status = 200) ?(headers = [ ("content-type", "application/json") ])
    body =
  { Masc_http_client.status; headers; body }

let recording () =
  let sent = ref [] in
  let answer = ref (fun (_ : string) -> response "{}") in
  let post ~url ~headers ~body =
    sent := (url, headers, body) :: !sent;
    Ok (!answer body)
  in
  (post, sent, answer)

let sent_bodies sent = List.rev_map (fun (_, _, body) -> body) !sent

let method_of body =
  match Yojson.Safe.from_string body with
  | `Assoc pairs -> (
      match List.assoc_opt "method" pairs with
      | Some (`String name) -> name
      | Some _ | None -> "")
  | _ -> ""

let request_id body =
  match Yojson.Safe.from_string body with
  | `Assoc pairs -> (match List.assoc_opt "id" pairs with Some (`Int id) -> id | _ -> 0)
  | _ -> 0

(* The most recent request. A session id only exists after initialize, so
   reading the first request would report None for a session that is being
   carried perfectly well. *)
let header_of sent name =
  match !sent with
  | (_, headers, _) :: _ -> List.assoc_opt name headers
  | [] -> None

let initialize_answer version =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":%S,"capabilities":{"tools":{}},"serverInfo":{"name":"Atlassian","version":"1"}}}|}
    version

let supported_version = Mcp_transport_protocol.default_protocol_version

let connect_or_fail ?(session_header = []) post answer =
  (answer :=
     fun body ->
       if String.equal (method_of body) "initialize" then
         response
           ~headers:(("content-type", "application/json") :: session_header)
           (initialize_answer supported_version)
       else response "{}");
  match
    Mcp_client.connect ~post ~url:"https://mcp.example.com/v1/mcp"
      ~access_token:"the-token" ()
  with
  | Ok client -> client
  | Error err ->
      Alcotest.failf "connect failed: %s" (Mcp_client.error_to_string err)

(* ── the handshake ───────────────────────────────────────────────────── *)

let test_the_handshake_is_initialize_then_initialized () =
  let post, sent, answer = recording () in
  let _ = connect_or_fail post answer in
  check (Alcotest.list str) "in order"
    [ "server/discover"; "initialize"; "notifications/initialized" ]
    (List.map method_of (sent_bodies sent))

let test_the_token_travels_as_a_bearer () =
  let post, sent, answer = recording () in
  let _ = connect_or_fail post answer in
  check (Alcotest.option str) "authorization" (Some "Bearer the-token")
    (header_of sent "Authorization")

let test_both_answer_shapes_are_accepted () =
  (* Streamable HTTP lets the server answer either way; refusing one would
     make its choice into our failure. *)
  let post, sent, answer = recording () in
  let _ = connect_or_fail post answer in
  check (Alcotest.option str) "accept"
    (Some "application/json, text/event-stream")
    (header_of sent "Accept")

let test_a_minted_session_is_carried () =
  let post, sent, answer = recording () in
  let _ =
    connect_or_fail ~session_header:[ ("Mcp-Session-Id", "sess-42") ] post answer
  in
  check (Alcotest.option str) "later requests name the session" (Some "sess-42")
    (header_of sent "Mcp-Session-Id")

let test_no_session_is_not_a_failure () =
  (* The stateless revisions mint none. *)
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  check (Alcotest.option str) "none" None (Mcp_client.session_id client)

let test_the_version_kept_is_the_one_the_server_named () =
  (* Not the one this offered. The two are usually the same and that is
     exactly why a mistake here would sit unnoticed until a server picked an
     older revision and every later request claimed the newer one. *)
  let post, sent, answer = recording () in
  let older = List.find (fun version ->
      not (Mcp_transport_protocol.is_stateless_protocol_version version)
      && not (String.equal version supported_version))
      Mcp_transport_protocol.supported_protocol_versions in
  (answer := fun _ -> response (initialize_answer older));
  match
    Mcp_client.connect ~post ~url:"https://mcp.example.com/v1/mcp"
      ~access_token:"the-token" ()
  with
  | Ok client ->
      check str "the server's answer" older
        (Mcp_client.negotiated_protocol_version client);
      check (Alcotest.option str) "and it is what later requests claim"
        (Some older)
        (header_of sent "MCP-Protocol-Version")
  | Error err ->
      Alcotest.failf "refused a version it supports: %s"
        (Mcp_client.error_to_string err)

let test_a_version_this_build_does_not_speak_is_refused () =
  let post, _, answer = recording () in
  (answer := fun _ -> response (initialize_answer "1999-01-01"));
  match
    Mcp_client.connect ~post ~url:"https://mcp.example.com/v1/mcp"
      ~access_token:"the-token" ()
  with
  | Ok _ ->
      Alcotest.fail "talked to a server in a dialect neither side agreed on"
  | Error _ -> ()

let test_a_refused_token_carries_where_to_get_one () =
  (* The live server answers exactly this; it is the only part of a 401
     worth acting on. *)
  let post, _, _ = recording () in
  let challenge =
    {|Bearer resource_metadata="https://mcp.atlassian.com/.well-known/oauth-protected-resource/v1/mcp/authv2", error="invalid_token"|}
  in
  let refusing ~url:_ ~headers:_ ~body:_ =
    Ok
      (response ~status:401
         ~headers:
           [ ("content-type", "application/json");
             ("www-authenticate", challenge) ]
         {|{"error":"invalid_token"}|})
  in
  ignore post;
  match
    Mcp_client.connect ~post:refusing ~url:"https://mcp.atlassian.com/v1/mcp/authv2"
      ~access_token:"stale" ()
  with
  | Ok _ -> Alcotest.fail "accepted a refused token"
  | Error (Mcp_client.Unauthorized { resource_metadata }) ->
      check (Alcotest.option str) "the pointer is kept"
        (Some
           "https://mcp.atlassian.com/.well-known/oauth-protected-resource/v1/mcp/authv2")
        resource_metadata
  | Error err ->
      Alcotest.failf "read a 401 as something else: %s"
        (Mcp_client.error_to_string err)

let test_a_pointer_inside_another_parameter_is_not_one () =
  (* The same letters, inside error_description's quoted value. The header
     is read by its grammar, which keeps them there. *)
  let challenge =
    {|Bearer error="invalid_token", error_description="see resource_metadata=\"https://mcp.atlassian.com/.well-known/oauth-protected-resource\""|}
  in
  let refusing ~url:_ ~headers:_ ~body:_ =
    Ok
      (response ~status:401
         ~headers:
           [ ("content-type", "application/json");
             ("www-authenticate", challenge) ]
         {|{"error":"invalid_token"}|})
  in
  match
    Mcp_client.connect ~post:refusing ~url:"https://mcp.atlassian.com/v1/mcp/authv2"
      ~access_token:"stale" ()
  with
  | Ok _ -> Alcotest.fail "accepted a refused token"
  | Error (Mcp_client.Unauthorized { resource_metadata }) ->
      check (Alcotest.option str) "no pointer was read" None resource_metadata
  | Error err ->
      Alcotest.failf "read a 401 as something else: %s"
        (Mcp_client.error_to_string err)

(* ── the tools ───────────────────────────────────────────────────────── *)

let tools_answer =
  {|{"jsonrpc":"2.0","id":2,"result":{"tools":[
      {"name":"getJiraIssue","description":"Read one issue","inputSchema":{"type":"object","properties":{"key":{"type":"string"}}}},
      {"name":"noSchema"}
    ]}}|}

let test_tools_come_back_with_their_schemas () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  (answer := fun _ -> response tools_answer);
  match Mcp_client.list_tools ~post client with
  | Error err ->
      Alcotest.failf "tools/list failed: %s" (Mcp_client.error_to_string err)
  | Ok tools ->
      check (Alcotest.list str) "names" [ "getJiraIssue"; "noSchema" ]
        (List.map (fun (t : Mcp_client.tool) -> t.name) tools);
      let first = List.hd tools in
      check str "description" "Read one issue" first.description;
      (* A tool that declares none takes no arguments; a runtime cannot be
         handed a tool it has no way to describe. *)
      let second = List.nth tools 1 in
      check str "a missing schema becomes an empty object"
        {|{"type":"object","properties":{}}|}
        (Yojson.Safe.to_string second.input_schema)

(* Compact, the way a server sends it: one message on one [data:] line. *)
let one_line json = Yojson.Safe.to_string (Yojson.Safe.from_string json)

let test_an_event_stream_answer_is_read () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  (answer :=
     fun _ ->
       response
         ~headers:[ ("content-type", "text/event-stream; charset=utf-8") ]
         (Printf.sprintf "event: message\r\ndata: %s\r\n\r\n"
            (one_line tools_answer)));
  match Mcp_client.list_tools ~post client with
  | Ok tools -> check Alcotest.int "same answer, other framing" 2 (List.length tools)
  | Error err ->
      Alcotest.failf "an event stream was not read: %s"
        (Mcp_client.error_to_string err)

let test_a_stream_ignores_what_came_before_the_answer () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  (answer :=
     fun _ ->
       response
         ~headers:[ ("content-type", "text/event-stream") ]
         (Printf.sprintf
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: %s\n\n"
            (one_line tools_answer)));
  match Mcp_client.list_tools ~post client with
  | Ok tools -> check Alcotest.int "the answer, not the progress note" 2 (List.length tools)
  | Error err ->
      Alcotest.failf "read the wrong message: %s" (Mcp_client.error_to_string err)

let test_a_payload_split_across_data_lines_is_joined () =
  (* One event may carry several [data:] lines and they are one message.
     Reading each as its own would find nothing parseable in any of them. *)
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  let compact = one_line tools_answer in
  let half = String.length compact / 2 in
  (answer :=
     fun _ ->
       response
         ~headers:[ ("content-type", "text/event-stream") ]
         (Printf.sprintf "event: message\ndata: %s\ndata: %s\n\n"
            (String.sub compact 0 half)
            (String.sub compact half (String.length compact - half))));
  match Mcp_client.list_tools ~post client with
  | Ok tools -> check Alcotest.int "joined back into one message" 2 (List.length tools)
  | Error err ->
      Alcotest.failf "a split payload was not joined: %s"
        (Mcp_client.error_to_string err)

let test_a_failed_tool_is_not_a_failed_call () =
  (* A tool that says no is an answer to show a model. A call that did not
     happen is not. Folding them together would make the model reason from
     an error it cannot see the shape of. *)
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  (answer :=
     fun _ ->
       response
         {|{"jsonrpc":"2.0","id":3,"result":{"isError":true,"content":[{"type":"text","text":"no such issue"}]}}|});
  match Mcp_client.call_tool ~post client ~name:"getJiraIssue" ~arguments:(`Assoc []) with
  | Ok result ->
      check Alcotest.bool "the tool said no" true result.is_error;
      check str "and said why" "no such issue" result.text
  | Error err ->
      Alcotest.failf "a tool refusal was read as a transport failure: %s"
        (Mcp_client.error_to_string err)

let test_a_refused_call_is_an_error () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  (answer :=
     fun _ ->
       response
         {|{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"unknown tool"}}|});
  match Mcp_client.call_tool ~post client ~name:"nope" ~arguments:(`Assoc []) with
  | Error (Mcp_client.Rpc { code; message; _ }) ->
      check Alcotest.int "code" (-32602) code;
      check str "message" "unknown tool" message
  | Error err ->
      Alcotest.failf "read a JSON-RPC error as something else: %s"
        (Mcp_client.error_to_string err)
  | Ok _ -> Alcotest.fail "a JSON-RPC error was read as a result"

let test_ambiguous_rpc_error_is_not_a_pre_effect_refusal () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  answer := (fun _ -> response
      {|{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"code":-32603,"message":"ambiguous"}}|});
  match Mcp_client.call_tool ~post client ~name:"x" ~arguments:(`Assoc []) with
  | Error (Mcp_client.Malformed _) -> ()
  | Error error -> Alcotest.failf "wrong error: %s" (Mcp_client.error_to_string error)
  | Ok _ -> Alcotest.fail "accepted an ambiguous error"

let test_a_block_that_is_not_text_is_named () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  (answer :=
     fun _ ->
       response
         {|{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"here"},{"type":"image","data":"..."}]}}|});
  match Mcp_client.call_tool ~post client ~name:"x" ~arguments:(`Assoc []) with
  | Ok result -> check str "nothing vanishes" "here\n[image]" result.text
  | Error err -> Alcotest.failf "call failed: %s" (Mcp_client.error_to_string err)

let test_malformed_error_flag_is_not_success () =
  List.iter
    (fun result ->
      let post, _, answer = recording () in
      let client = connect_or_fail post answer in
      answer := (fun _ -> response
          ("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":" ^ result ^ "}"));
      match Mcp_client.call_tool ~post client ~name:"x" ~arguments:(`Assoc []) with
      | Error (Mcp_client.Malformed _) -> ()
      | Error error -> Alcotest.failf "wrong error: %s" (Mcp_client.error_to_string error)
      | Ok _ -> Alcotest.fail "malformed tool error was reported as success")
    [ {|{"content":[],"isError":"true"}|};
      {|{"content":[],"isError":false,"isError":true}|};
      {|{"content":"not an array"}|} ]

let test_forbidden_is_not_a_refreshable_401 () =
  let refusing ~url:_ ~headers:_ ~body:_ =
    Ok (response ~status:403
          ~headers:[ "www-authenticate", {|Bearer scope="read"|};
                     "www-authenticate",
                     {|Bearer error="insufficient_scope", scope="read write", resource_metadata="https://example.com/meta"|} ]
          {|{"error":"insufficient_scope"}|})
  in
  match Mcp_client.connect ~post:refusing ~url:"https://mcp.example.com"
          ~access_token:"token" () with
  | Error (Mcp_client.Http { status; bearer_error; required_scope; resource_metadata; www_authenticate; _ }) ->
      check Alcotest.int "forbidden stays distinguishable" 403 status;
      check (Alcotest.option str) "bearer error retained" (Some "insufficient_scope") bearer_error;
      check (Alcotest.option str) "required scope retained" (Some "read write") required_scope;
      check (Alcotest.option str) "metadata retained" (Some "https://example.com/meta") resource_metadata;
      check Alcotest.int "challenges retained" 2 (List.length www_authenticate)
  | Error err -> Alcotest.failf "wrong failure: %s" (Mcp_client.error_to_string err)
  | Ok _ -> Alcotest.fail "accepted a forbidden request"

let test_modern_discovery_and_request_headers () =
  let post, sent, answer = recording () in
  answer := (fun body ->
      match method_of body with
      | "server/discover" -> response
          {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|}
      | "tools/list" -> response
          {|{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"Hello, 세계","inputSchema":{"type":"object","properties":{"filter":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}}}}}}],"ttlMs":0,"cacheScope":"private"}}|}
      | "tools/call" -> response
          (Printf.sprintf {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"complete","content":[{"type":"text","text":"ok"}]}}|} (request_id body))
      | _ -> response "{}");
  let client =
    match Mcp_client.connect ~post ~url:"https://mcp.example.com"
            ~access_token:"token" () with
    | Ok client -> client
    | Error error -> Alcotest.failf "discovery failed: %s" (Mcp_client.error_to_string error)
  in
  check str "modern version" "2026-07-28" (Mcp_client.negotiated_protocol_version client);
  (match Mcp_client.call_tool ~post client ~name:"Hello, 세계"
           ~arguments:(`Assoc [ "filter", `Assoc [ "region", `String " 서울 " ] ]) with
   | Ok result -> check str "call succeeded" "ok" result.text
   | Error error -> Alcotest.failf "call failed: %s" (Mcp_client.error_to_string error));
  check (Alcotest.list str) "modern flow has no initialize"
    [ "server/discover"; "tools/list"; "tools/call" ] (List.map method_of (sent_bodies sent));
  check (Alcotest.option str) "method header" (Some "tools/call") (header_of sent "Mcp-Method");
  check (Alcotest.option str) "encoded name header" (Some "=?base64?SGVsbG8sIOyEuOqzhA==?=") (header_of sent "Mcp-Name");
  check (Alcotest.option str) "nested parameter header"
    (Some (Mcp_transport_protocol.encode_header_value " 서울 ")) (header_of sent "Mcp-Param-Region");
  check (Alcotest.option str) "version header" (Some "2026-07-28") (header_of sent "MCP-Protocol-Version");
  let _, _, body = List.hd !sent in
  let open Yojson.Safe.Util in
  let meta = Yojson.Safe.from_string body |> member "params" |> member "_meta" in
  check str "per-request version" "2026-07-28"
    (meta |> member "io.modelcontextprotocol/protocolVersion" |> to_string);
  check Alcotest.bool "capabilities supplied" true
    (match meta |> member "io.modelcontextprotocol/clientCapabilities" with `Assoc [] -> true | _ -> false)

let test_modern_header_error_does_not_fall_back () =
  let post, sent, answer = recording () in
  answer := (fun _ -> response ~status:400
      {|{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"Header mismatch"}}|});
  (match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
   | Error (Mcp_client.Rpc { code = -32020; http_status = Some 400; _ }) -> ()
   | Error error -> Alcotest.failf "wrong failure: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "accepted a rejected modern request");
  check (Alcotest.list str) "no legacy retry after modern rejection"
    [ "server/discover" ] (List.map method_of (sent_bodies sent))

let test_unsupported_modern_version_falls_back_to_advertised_legacy () =
  let post, sent, answer = recording () in
  answer := (fun body ->
      match method_of body with
      | "server/discover" -> response ~status:400
          {|{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2025-11-25"],"requested":"2026-07-28"}}}|}
      | "initialize" -> response (initialize_answer supported_version)
      | _ -> response "{}");
  (match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
   | Ok client -> check str "legacy version selected" supported_version (Mcp_client.negotiated_protocol_version client)
   | Error error -> Alcotest.failf "fallback failed: %s" (Mcp_client.error_to_string error));
  check (Alcotest.list str) "only discovery and legacy handshake"
    [ "server/discover"; "initialize"; "notifications/initialized" ]
    (List.map method_of (sent_bodies sent))

let test_response_id_must_match_the_request () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  answer := (fun _ -> response
      {|{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"wrong-response"}]}}|});
  match Mcp_client.list_tools ~post client with
  | Error (Mcp_client.Malformed _) -> ()
  | Error error -> Alcotest.failf "wrong error: %s" (Mcp_client.error_to_string error)
  | Ok _ -> Alcotest.fail "accepted another request's response"

let test_timed_out_call_id_is_not_reused () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  let ids = ref [] in
  let calls = ref 0 in
  let failing_then_answering ~url:_ ~headers:_ ~body =
    ids := request_id body :: !ids;
    incr calls;
    if !calls = 1 then Error "timeout"
    else Ok (response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"content":[]}}|} (request_id body)))
  in
  ignore (Mcp_client.call_tool ~post:failing_then_answering client ~name:"x" ~arguments:(`Assoc []));
  (match Mcp_client.call_tool ~post:failing_then_answering client ~name:"x" ~arguments:(`Assoc []) with
   | Ok _ -> ()
   | Error error -> Alcotest.failf "second call: %s" (Mcp_client.error_to_string error));
  match !ids with
  | [ later; earlier ] -> check Alcotest.bool "request IDs differ" true (later <> earlier)
  | _ -> Alcotest.fail "expected two tool requests"

let test_modern_schema_headers_and_invalid_tools () =
  let post, sent, answer = recording () in
  answer := (fun body ->
      match method_of body with
      | "server/discover" -> response
          {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|}
      | "tools/list" -> response
          {|{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"valid","inputSchema":{"type":"object","properties":{"count":{"type":"integer","x-mcp-header":"Count","minimum":1},"flag":{"type":"boolean","x-mcp-header":"Flag"},"text":{"type":"string","x-mcp-header":"Text"}}}},{"name":"duplicate","inputSchema":{"type":"object","properties":{"a":{"type":"string","x-mcp-header":"Key"},"b":{"type":"string","x-mcp-header":"key"}}}},{"name":"unreachable","inputSchema":{"anyOf":[{"properties":{"a":{"type":"string","x-mcp-header":"A"}}}]}},{"name":"tuple-items","inputSchema":{"$schema":"http://json-schema.org/draft-07/schema#","properties":{"items":{"type":"array","items":[{"type":"string","x-mcp-header":"Item"}]}}}},{"name":"number","inputSchema":{"properties":{"a":{"type":"number","x-mcp-header":"A"}}}}],"ttlMs":0,"cacheScope":"private"}}|}
      | "tools/call" -> response
          (Printf.sprintf {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"complete","content":[{"type":"text","text":"ok"}]}}|} (request_id body))
      | _ -> response "{}");
  let client = match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
    | Ok client -> client
    | Error error -> Alcotest.failf "connect: %s" (Mcp_client.error_to_string error) in
  (match Mcp_client.list_tools ~post client with
   | Ok tools -> check (Alcotest.list str) "invalid annotations excluded" [ "valid" ]
       (List.map (fun (tool : Mcp_client.tool) -> tool.name) tools)
   | Error error -> Alcotest.failf "list: %s" (Mcp_client.error_to_string error));
  let before_drift = List.length !sent in
  List.iter
    (fun authority ->
      match Mcp_client.call_tool ~post ~catalog_authority:authority client ~name:"valid"
              ~arguments:(`Assoc []) with
      | Error (Mcp_client.Before_tool_call (Mcp_client.Malformed _)) -> ()
      | Error error -> Alcotest.failf "wrong drift error: %s" (Mcp_client.error_to_string error)
      | Ok _ -> Alcotest.fail "unbound or changed approval schema was accepted")
    [ Mcp_client.Bound None;
      Mcp_client.Bound (Some { Mcp_client.input_schema = `Assoc []; read_only = None }) ];
  check Alcotest.int "schema mismatch sends no tool request" before_drift (List.length !sent);
  let reordered_schema = Yojson.Safe.from_string
      {|{"properties":{"text":{"x-mcp-header":"Text","type":"string"},"flag":{"type":"boolean","x-mcp-header":"Flag"},"count":{"minimum":1.0,"x-mcp-header":"Count","type":"integer"}},"type":"object"}|} in
  (match Mcp_client.call_tool ~post ~catalog_authority:
           (Mcp_client.Bound (Some { Mcp_client.input_schema = reordered_schema; read_only = Some true }))
           client ~name:"valid" ~arguments:(`Assoc []) with
   | Error (Mcp_client.Before_tool_call (Mcp_client.Malformed _)) -> ()
   | Error error -> Alcotest.failf "wrong annotation drift error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "changed read-only hint was accepted");
  (match Mcp_client.call_tool ~post ~catalog_authority:
           (Mcp_client.Bound (Some { Mcp_client.input_schema = reordered_schema; read_only = None })) client ~name:"valid"
           ~arguments:(`Assoc [ "count", `Int 42; "flag", `Bool false; "text", `String "line\nvalue" ]) with
   | Ok _ -> ()
   | Error error -> Alcotest.failf "call: %s" (Mcp_client.error_to_string error));
  check (Alcotest.option str) "integer header" (Some "42") (header_of sent "Mcp-Param-Count");
  check (Alcotest.option str) "boolean header" (Some "false") (header_of sent "Mcp-Param-Flag");
  check (Alcotest.option str) "newline encoded" (Some "=?base64?bGluZQp2YWx1ZQ==?=") (header_of sent "Mcp-Param-Text");
  (match Mcp_client.call_tool ~post client ~name:"valid"
           ~arguments:(`Assoc [ "count", `Float 42.0 ]) with
   | Ok _ -> ()
   | Error error -> Alcotest.failf "integral float: %s" (Mcp_client.error_to_string error));
  check (Alcotest.option str) "integral JSON number header" (Some "42") (header_of sent "Mcp-Param-Count");
  answer := (fun body -> response ~status:400 (Printf.sprintf
      {|{"jsonrpc":"2.0","id":%d,"error":{"code":-32602,"message":"invalid params"}}|}
      (request_id body)));
  (match Mcp_client.call_tool ~post client ~name:"valid" ~arguments:(`Assoc []) with
   | Error (Mcp_client.Rpc { code = -32602; http_status = Some 400; _ }) -> ()
   | Error error -> Alcotest.failf "wrong HTTP RPC error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "accepted invalid params");
  let before = List.length !sent in
  (match Mcp_client.call_tool ~post client ~name:"valid"
           ~arguments:(`Assoc [ "count", `Intlit "9007199254740992" ]) with
   | Error (Mcp_client.Before_tool_call (Mcp_client.Malformed _)) -> ()
   | Error error -> Alcotest.failf "wrong error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "unsafe integer was sent");
  check Alcotest.int "invalid value does not send a call" before (List.length !sent)

let test_state_only_continuation_binds_the_original_call () =
  let post, sent, answer = recording () in
  let calls = ref 0 in
  let first_state = "opaque\nstate=1" in
  answer := (fun body ->
    match method_of body with
    | "server/discover" -> response
        {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|}
    | "tools/list" -> response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"complete","tools":[{"name":"remote","inputSchema":{"type":"object"}}],"ttlMs":0,"cacheScope":"private"}}|}
        (request_id body))
    | "tools/call" ->
      incr calls;
      let result = match !calls with
        | 1 -> `Assoc [ "resultType", `String "input_required"; "requestState", `String first_state ]
        | 2 -> `Assoc [ "resultType", `String "input_required"; "requestState", `String "" ]
        | _ -> `Assoc [ "resultType", `String "complete"; "content", `List [] ] in
      response (Yojson.Safe.to_string (`Assoc
        [ "jsonrpc", `String "2.0"; "id", `Int (request_id body); "result", result ]))
    | _ -> response "{}");
  let client = match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
    | Ok client -> client | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  let args = `Assoc [ "x", `String "original" ] in
  let first = match Mcp_client.start_tool_with_continuation ~post client ~name:"remote" ~arguments:args with
    | Ok (Mcp_client.Tool_continuation value) -> value
    | Ok (Mcp_client.Tool_completed _) -> Alcotest.fail "incomplete call became complete"
    | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  let second = match Mcp_client.resume_tool_with_state ~post first with
    | Ok (Mcp_client.Tool_continuation value) -> value
    | Ok (Mcp_client.Tool_completed _) -> Alcotest.fail "second incomplete round became complete"
    | Error (Mcp_client.Continuation_failed error) -> Alcotest.fail (Mcp_client.error_to_string error)
    | Error Mcp_client.Continuation_consumed -> Alcotest.fail "fresh continuation was already consumed" in
  let before_reuse = List.length !sent in
  (match Mcp_client.resume_tool_with_state ~post first with
   | Error Mcp_client.Continuation_consumed -> ()
   | Ok _ | Error (Mcp_client.Continuation_failed _) -> Alcotest.fail "a used continuation was reusable");
  check Alcotest.int "reuse sends nothing" before_reuse (List.length !sent);
  (match Mcp_client.resume_tool_with_state ~post second with
   | Ok (Mcp_client.Tool_completed _) -> ()
   | Ok (Mcp_client.Tool_continuation _) | Error _ -> Alcotest.fail "final round failed");
  let requests = sent_bodies sent |> List.filter (fun body -> method_of body = "tools/call") in
  check Alcotest.int "exactly three rounds" 3 (List.length requests);
  let ids = List.map request_id requests in
  check Alcotest.int "every round has its own ID" 3 (List.length (List.sort_uniq Int.compare ids));
  List.iteri (fun index body ->
    let params = Yojson.Safe.from_string body |> Yojson.Safe.Util.member "params" in
    check Alcotest.bool "original tool and arguments are retained" true
      (Yojson.Safe.Util.member "name" params = `String "remote"
       && Yojson.Safe.Util.member "arguments" params = args);
    if index = 0 then
      (match params with
       | `Assoc fields -> check Alcotest.bool "initial request omits state" false (List.mem_assoc "requestState" fields)
       | _ -> Alcotest.fail "request params are not an object");
    let expected = match index with 0 -> `Null | 1 -> `String first_state | _ -> `String "" in
    check Alcotest.bool "opaque state is echoed exactly" true
      (Yojson.Safe.Util.member "requestState" params = expected)) requests

let test_state_only_continuation_rejects_server_input_requests () =
  let post, _, answer = recording () in
  answer := (fun body ->
    match method_of body with
    | "server/discover" -> response
        {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|}
    | "tools/list" -> response
        {|{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"remote","inputSchema":{"type":"object"}}],"ttlMs":0,"cacheScope":"private"}}|}
    | "tools/call" -> response
        {|{"jsonrpc":"2.0","id":3,"result":{"resultType":"input_required","inputRequests":{"ask":{"method":"elicitation/create","params":{}}},"requestState":"opaque"}}|}
    | _ -> response "{}");
  let client = match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
    | Ok client -> client | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  match Mcp_client.start_tool_with_continuation ~post client ~name:"remote" ~arguments:(`Assoc []) with
  | Error (Mcp_client.Input_required { input_requests = Some _; _ }) -> ()
  | Error error -> Alcotest.fail (Mcp_client.error_to_string error)
  | Ok _ -> Alcotest.fail "unsupported input request became a state-only continuation"

let test_continuation_rechecks_catalog_and_does_not_replay_lost_response () =
  let sent = ref [] in
  let schema = ref (`Assoc [ "type", `String "object" ]) in
  let calls = ref 0 in
  let post ~url:_ ~headers:_ ~body =
    sent := body :: !sent;
    let id = request_id body in
    match method_of body with
    | "server/discover" -> Ok (response
        {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|})
    | "tools/list" -> Ok (response (Yojson.Safe.to_string (`Assoc
        [ "jsonrpc", `String "2.0"; "id", `Int id; "result", `Assoc
          [ "resultType", `String "complete"; "ttlMs", `Int 0; "cacheScope", `String "private"
          ; "tools", `List [ `Assoc [ "name", `String "remote"; "inputSchema", !schema ] ] ] ])))
    | "tools/call" ->
      incr calls;
      if !calls = 1 then Ok (response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"input_required","requestState":"opaque"}}|} id))
      else Error "response lost"
    | _ -> Ok (response "{}") in
  let client = match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
    | Ok client -> client | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  let continuation = match Mcp_client.start_tool_with_continuation ~post client ~name:"remote" ~arguments:(`Assoc []) with
    | Ok (Mcp_client.Tool_continuation value) -> value
    | Ok (Mcp_client.Tool_completed _) -> Alcotest.fail "expected a continuation"
    | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  schema := `Assoc [ "type", `String "object"; "properties", `Assoc [ "changed", `Assoc [ "type", `String "boolean" ] ] ];
  (match Mcp_client.resume_tool_with_state ~post continuation with
   | Error (Mcp_client.Continuation_failed (Mcp_client.Before_tool_call (Mcp_client.Malformed _))) -> ()
   | Ok _ | Error _ -> Alcotest.fail "changed catalog did not block the continuation");
  check Alcotest.int "catalog drift sends no continuation" 1 !calls;
  schema := `Assoc [ "type", `String "object" ];
  (match Mcp_client.resume_tool_with_state ~post continuation with
   | Error (Mcp_client.Continuation_failed (Mcp_client.Transport _)) -> ()
   | Ok _ | Error _ -> Alcotest.fail "expected a lost post-send response");
  let before_reuse = List.length !sent in
  (match Mcp_client.resume_tool_with_state ~post continuation with
   | Error Mcp_client.Continuation_consumed -> ()
   | Ok _ | Error _ -> Alcotest.fail "lost response permitted a replay");
  check Alcotest.int "post-send retry sent nothing" before_reuse (List.length !sent);
  check Alcotest.int "the continuation was sent only once" 2 !calls

let test_concurrent_continuation_has_one_sender () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let started, start = Eio.Promise.create () in
  let release, release_sender = Eio.Promise.create () in
  let both_preflight, both_ready = Eio.Promise.create () in
  let release_preflight, release_both = Eio.Promise.create () in
  let first_done, finish_first = Eio.Promise.create () in
  let second_done, finish_second = Eio.Promise.create () in
  let calls = ref 0 and listings = ref 0 in
  let post ~url:_ ~headers:_ ~body =
    let id = request_id body in
    match method_of body with
    | "server/discover" -> Ok (response
        {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|})
    | "tools/list" ->
      incr listings;
      if !listings > 1 then (
        if !listings = 3 then Eio.Promise.resolve both_ready ();
        Eio.Promise.await release_preflight);
      Ok (response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"complete","tools":[{"name":"remote","inputSchema":{"type":"object"}}],"ttlMs":0,"cacheScope":"private"}}|} id))
    | "tools/call" ->
      incr calls;
      if !calls = 1 then Ok (response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"input_required","requestState":"opaque"}}|} id))
      else (
        Eio.Promise.resolve start ();
        Eio.Promise.await release;
        Ok (response (Printf.sprintf
          {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"complete","content":[]}}|} id)))
    | _ -> Ok (response "{}") in
  let client = match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
    | Ok client -> client | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  let continuation = match Mcp_client.start_tool_with_continuation ~post client ~name:"remote" ~arguments:(`Assoc []) with
    | Ok (Mcp_client.Tool_continuation value) -> value
    | Ok (Mcp_client.Tool_completed _) -> Alcotest.fail "expected a continuation"
    | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finish_first (Mcp_client.resume_tool_with_state ~post continuation));
  Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finish_second (Mcp_client.resume_tool_with_state ~post continuation));
  Eio.Promise.await both_preflight;
  Eio.Promise.resolve release_both ();
  Eio.Promise.await started;
  let rec await_loser () =
    if Eio.Promise.is_resolved first_done then Eio.Promise.await first_done
    else if Eio.Promise.is_resolved second_done then Eio.Promise.await second_done
    else (Eio.Fiber.yield (); await_loser ()) in
  (match await_loser () with
   | Error Mcp_client.Continuation_consumed -> ()
   | Ok _ | Error _ -> Alcotest.fail "concurrent caller did not lose the claim");
  check Alcotest.int "only one continuation reached the transport" 2 !calls;
  Eio.Promise.resolve release_sender ();
  let first = Eio.Promise.await first_done and second = Eio.Promise.await second_done in
  match first, second with
  | Ok (Mcp_client.Tool_completed _), Error Mcp_client.Continuation_consumed
  | Error Mcp_client.Continuation_consumed, Ok (Mcp_client.Tool_completed _) -> ()
  | _ -> Alcotest.fail "claimed continuation failed"

let test_cancelled_continuation_cannot_be_sent_again () =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 @@ fun () ->
  let started, start = Eio.Promise.create () in
  let hold, _release = Eio.Promise.create () in
  let calls = ref 0 in
  let post ~url:_ ~headers:_ ~body =
    let id = request_id body in
    match method_of body with
    | "server/discover" -> Ok (response
        {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|})
    | "tools/list" -> Ok (response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"complete","tools":[{"name":"remote","inputSchema":{"type":"object"}}],"ttlMs":0,"cacheScope":"private"}}|} id))
    | "tools/call" ->
      incr calls;
      if !calls = 1 then Ok (response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"resultType":"input_required","requestState":"opaque"}}|} id))
      else (
        Eio.Promise.resolve start ();
        Eio.Promise.await hold;
        Ok (response "{}"))
    | _ -> Ok (response "{}") in
  let client = match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
    | Ok client -> client | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  let continuation = match Mcp_client.start_tool_with_continuation ~post client ~name:"remote" ~arguments:(`Assoc []) with
    | Ok (Mcp_client.Tool_continuation value) -> value
    | Ok (Mcp_client.Tool_completed _) -> Alcotest.fail "expected a continuation"
    | Error error -> Alcotest.fail (Mcp_client.error_to_string error) in
  let outcome = Eio.Fiber.first
    (fun () -> ignore (Mcp_client.resume_tool_with_state ~post continuation); `Unexpected_response)
    (fun () -> Eio.Promise.await started; `Cancelled) in
  check Alcotest.bool "the in-flight request was cancelled" true (outcome = `Cancelled);
  (match Mcp_client.resume_tool_with_state ~post continuation with
   | Error Mcp_client.Continuation_consumed -> ()
   | Ok _ | Error _ -> Alcotest.fail "a cancelled send was reusable");
  check Alcotest.int "cancelled continuation was sent once" 2 !calls

let test_modern_results_require_result_type_and_object_tool_schema () =
  let post, _, answer = recording () in
  let valid_list = ref false in
  answer := (fun body ->
    let id = request_id body in
    match method_of body with
    | "server/discover" -> response
        {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|}
    | "tools/list" ->
      let fields = if !valid_list then {|"resultType":"complete",|} else "" in
      response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{%s"tools":[{"name":"valid","inputSchema":{"type":"object"}},{"name":"invalid","inputSchema":{"properties":{}}}],"ttlMs":0,"cacheScope":"private"}}|}
        id fields)
    | "tools/call" -> response (Printf.sprintf
        {|{"jsonrpc":"2.0","id":%d,"result":{"content":[]}}|} id)
    | _ -> response "{}");
  let client = match Mcp_client.connect ~post ~url:"https://mcp.example.com" ~access_token:"token" () with
    | Ok client -> client
    | Error error -> Alcotest.failf "connect: %s" (Mcp_client.error_to_string error) in
  (match Mcp_client.list_tools ~post client with
   | Error (Mcp_client.Malformed _) -> ()
   | Error error -> Alcotest.failf "wrong list error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "modern tools/list accepted absent resultType");
  valid_list := true;
  (match Mcp_client.list_tools ~post client with
   | Ok tools -> check (Alcotest.list str) "only an object-root schema is exposed"
       [ "valid" ] (List.map (fun (tool : Mcp_client.tool) -> tool.name) tools)
   | Error error -> Alcotest.failf "valid list: %s" (Mcp_client.error_to_string error));
  (match Mcp_client.call_tool ~post client ~name:"valid" ~arguments:(`Assoc []) with
   | Error (Mcp_client.Malformed _) -> ()
   | Error error -> Alcotest.failf "wrong call error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "modern tools/call accepted absent resultType")

let test_legacy_bound_call_checks_the_live_catalog () =
  let post, sent, answer = recording () in
  let client = connect_or_fail post answer in
  answer := (fun body ->
    match method_of body with
    | "tools/list" -> response
        {|{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"remote","inputSchema":{"type":"object","properties":{"key":{"type":"string"}}},"annotations":{"readOnlyHint":true}}]}}|}
    | "tools/call" -> response
        {|{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"ok"}]}}|}
    | _ -> response "{}");
  (match Mcp_client.call_tool ~post ~catalog_authority:(Mcp_client.Bound None)
           client ~name:"remote" ~arguments:(`Assoc []) with
   | Error (Mcp_client.Before_tool_call (Mcp_client.Malformed _)) -> ()
   | Error error -> Alcotest.failf "wrong missing-binding error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "legacy call accepted an approval without a schema");
  let changed = Mcp_client.Bound (Some { Mcp_client.input_schema = `Assoc []; read_only = Some true }) in
  (match Mcp_client.call_tool ~post ~catalog_authority:changed client ~name:"remote" ~arguments:(`Assoc []) with
   | Error (Mcp_client.Before_tool_call (Mcp_client.Malformed _)) -> ()
   | Error error -> Alcotest.failf "wrong changed-schema error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "legacy call accepted changed authority");
  check (Alcotest.list str) "changed schema sends a list but no tool call"
    [ "server/discover"; "initialize"; "notifications/initialized"; "tools/list" ]
    (List.map method_of (sent_bodies sent));
  let schema = Yojson.Safe.from_string
      {|{"properties":{"key":{"type":"string"}},"type":"object"}|} in
  let binding = Mcp_client.Bound (Some { Mcp_client.input_schema = schema; read_only = Some true }) in
  (match Mcp_client.call_tool ~post ~catalog_authority:binding client ~name:"remote" ~arguments:(`Assoc []) with
   | Ok _ -> ()
   | Error error -> Alcotest.failf "matching legacy authority failed: %s" (Mcp_client.error_to_string error));
  check (Alcotest.list str) "matching authority sends the call once"
    [ "server/discover"; "initialize"; "notifications/initialized"; "tools/list"; "tools/call" ]
    (List.map method_of (sent_bodies sent))

let test_all_tool_pages_are_read_with_opaque_cursors () =
  let post, sent, answer = recording () in
  let client = connect_or_fail post answer in
  let count = ref 0 in
  answer := (fun body ->
      incr count;
      if !count = 1 then
        response (Printf.sprintf {|{"jsonrpc":"2.0","id":%d,"result":{"tools":[{"name":"first"}],"nextCursor":""}}|} (request_id body))
      else
        response (Printf.sprintf {|{"jsonrpc":"2.0","id":%d,"result":{"tools":[{"name":"second"}]}}|} (request_id body)));
  (match Mcp_client.list_tools ~post client with
   | Ok tools ->
     check (Alcotest.list str) "both pages" ["first"; "second"]
       (List.map (fun (tool : Mcp_client.tool) -> tool.name) tools)
   | Error error -> Alcotest.failf "pages failed: %s" (Mcp_client.error_to_string error));
  let last = List.hd !sent |> fun (_, _, body) -> Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  check str "empty cursor sent unchanged" "" (last |> member "params" |> member "cursor" |> to_string)

let test_input_required_is_not_reported_as_success () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  answer := (fun _ -> response
      {|{"jsonrpc":"2.0","id":3,"result":{"resultType":"input_required","inputRequests":{"ask":{"method":"elicitation/create","params":{}}},"requestState":"opaque"}}|});
  match Mcp_client.call_tool ~post client ~name:"x" ~arguments:(`Assoc []) with
  | Error (Mcp_client.Input_required { input_requests = Some (`Assoc _); request_state = Some state }) ->
      check str "opaque request state preserved" "opaque" state
  | Error error -> Alcotest.failf "wrong error: %s" (Mcp_client.error_to_string error)
  | Ok _ -> Alcotest.fail "an incomplete operation was reported as successful"

let test_repeated_cursor_is_still_opaque () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  let count = ref 0 in
  answer := (fun body ->
      incr count;
      if !count < 3 then
        response (Printf.sprintf {|{"jsonrpc":"2.0","id":%d,"result":{"tools":[],"nextCursor":"same"}}|} (request_id body))
      else response (Printf.sprintf {|{"jsonrpc":"2.0","id":%d,"result":{"tools":[{"name":"last"}]}}|} (request_id body)));
  match Mcp_client.list_tools ~post client with
  | Ok [ tool ] -> check str "later page was read" "last" tool.name
  | Ok _ -> Alcotest.fail "the last page was not returned"
  | Error error -> Alcotest.failf "cursor was interpreted: %s" (Mcp_client.error_to_string error)

let test_a_listing_that_never_ends_is_refused () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  let count = ref 0 in
  answer := (fun body ->
      incr count;
      response (Printf.sprintf {|{"jsonrpc":"2.0","id":%d,"result":{"tools":[],"nextCursor":"page-%d"}}|} (request_id body) !count));
  (match Mcp_client.list_tools ~post client with
   | Error (Mcp_client.Malformed detail) ->
     check str "the refusal says why"
       (Printf.sprintf "tools/list did not end within %d pages" Mcp_client.max_tools_list_pages)
       detail
   | Error error -> Alcotest.failf "wrong error: %s" (Mcp_client.error_to_string error)
   | Ok _ -> Alcotest.fail "an endless listing was read to its end");
  check Alcotest.int "it stopped at the bound" Mcp_client.max_tools_list_pages !count

let test_structured_only_tool_result_is_preserved () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  answer := (fun _ -> response
      {|{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","structuredContent":[1,"two"]}}|});
  match Mcp_client.call_tool ~post client ~name:"x" ~arguments:(`Assoc []) with
  | Ok result ->
      check (Alcotest.option Alcotest.string) "the exact value is retained"
        (Some {|[1,"two"]|})
        (Option.map Yojson.Safe.to_string result.structured_content);
      check str "a structured-only result is visible to the model" {|[1,"two"]|} (Mcp_client.model_text result)
  | Error error -> Alcotest.failf "call failed: %s" (Mcp_client.error_to_string error)

let test_structured_content_with_text_reaches_the_model () =
  let post, _, answer = recording () in
  let client = connect_or_fail post answer in
  answer := (fun _ -> response
      {|{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Found users"}],"structuredContent":[{"id":1}]}}|});
  match Mcp_client.call_tool ~post client ~name:"x" ~arguments:(`Assoc []) with
  | Ok result -> check str "both forms remain visible"
      "Found users\nstructuredContent: [{\"id\":1}]" (Mcp_client.model_text result);
      check str "original text remains machine-readable" "Found users" result.text
  | Error error -> Alcotest.failf "call failed: %s" (Mcp_client.error_to_string error)

let () =
  Alcotest.run "mcp_client"
    [ ( "handshake",
        [ Alcotest.test_case "initialize then initialized" `Quick
            test_the_handshake_is_initialize_then_initialized;
          Alcotest.test_case "the token travels as a bearer" `Quick
            test_the_token_travels_as_a_bearer;
          Alcotest.test_case "both answer shapes are accepted" `Quick
            test_both_answer_shapes_are_accepted;
          Alcotest.test_case "a minted session is carried" `Quick
            test_a_minted_session_is_carried;
          Alcotest.test_case "no session is not a failure" `Quick
            test_no_session_is_not_a_failure;
          Alcotest.test_case "the version kept is the one the server named"
            `Quick test_the_version_kept_is_the_one_the_server_named;
          Alcotest.test_case "a version this build does not speak is refused"
            `Quick test_a_version_this_build_does_not_speak_is_refused;
          Alcotest.test_case "a refused token carries where to get one" `Quick
            test_a_refused_token_carries_where_to_get_one;
          Alcotest.test_case "a pointer inside another parameter is not one" `Quick
            test_a_pointer_inside_another_parameter_is_not_one;
          Alcotest.test_case "forbidden is not a refreshable 401" `Quick
            test_forbidden_is_not_a_refreshable_401;
          Alcotest.test_case "modern discovery and request headers" `Quick
            test_modern_discovery_and_request_headers;
          Alcotest.test_case "modern header error does not fall back" `Quick
            test_modern_header_error_does_not_fall_back;
          Alcotest.test_case "unsupported modern version selects legacy" `Quick
            test_unsupported_modern_version_falls_back_to_advertised_legacy;
          Alcotest.test_case "response id must match" `Quick
            test_response_id_must_match_the_request;
          Alcotest.test_case "timed-out call id is not reused" `Quick
            test_timed_out_call_id_is_not_reused;
          Alcotest.test_case "modern schema headers and invalid tools" `Quick
            test_modern_schema_headers_and_invalid_tools;
          Alcotest.test_case "modern result type and object schema" `Quick
            test_modern_results_require_result_type_and_object_tool_schema;
          Alcotest.test_case "state-only continuation keeps the original call" `Quick
            test_state_only_continuation_binds_the_original_call;
          Alcotest.test_case "state-only continuation refuses input requests" `Quick
            test_state_only_continuation_rejects_server_input_requests;
          Alcotest.test_case "continuation checks catalog and never replays lost response" `Quick
            test_continuation_rechecks_catalog_and_does_not_replay_lost_response;
          Alcotest.test_case "concurrent continuation has one sender" `Quick
            test_concurrent_continuation_has_one_sender;
          Alcotest.test_case "cancelled continuation cannot be resent" `Quick
            test_cancelled_continuation_cannot_be_sent_again;
          Alcotest.test_case "legacy bound calls check live catalog" `Quick
            test_legacy_bound_call_checks_the_live_catalog;
        ] );
      ( "tools",
        [ Alcotest.test_case "tools come back with their schemas" `Quick
            test_tools_come_back_with_their_schemas;
          Alcotest.test_case "all tool pages and opaque cursors" `Quick
            test_all_tool_pages_are_read_with_opaque_cursors;
          Alcotest.test_case "repeated cursor remains opaque" `Quick
            test_repeated_cursor_is_still_opaque;
          Alcotest.test_case "a listing that never ends is refused" `Quick
            test_a_listing_that_never_ends_is_refused;
          Alcotest.test_case "an event stream answer is read" `Quick
            test_an_event_stream_answer_is_read;
          Alcotest.test_case "a stream ignores what came before the answer"
            `Quick test_a_stream_ignores_what_came_before_the_answer;
          Alcotest.test_case "a payload split across data lines is joined"
            `Quick test_a_payload_split_across_data_lines_is_joined;
          Alcotest.test_case "a failed tool is not a failed call" `Quick
            test_a_failed_tool_is_not_a_failed_call;
          Alcotest.test_case "a refused call is an error" `Quick
            test_a_refused_call_is_an_error;
          Alcotest.test_case "ambiguous RPC error is rejected" `Quick
            test_ambiguous_rpc_error_is_not_a_pre_effect_refusal;
          Alcotest.test_case "a block that is not text is named" `Quick
            test_a_block_that_is_not_text_is_named;
          Alcotest.test_case "malformed error flag is not success" `Quick
            test_malformed_error_flag_is_not_success;
          Alcotest.test_case "input required is not success" `Quick
            test_input_required_is_not_reported_as_success;
          Alcotest.test_case "structured-only result is retained" `Quick
            test_structured_only_tool_result_is_preserved;
          Alcotest.test_case "structured content with text is visible" `Quick
            test_structured_content_with_text_reaches_the_model;
        ] );
    ]
