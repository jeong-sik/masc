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
    [ "initialize"; "notifications/initialized" ]
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
  let older = List.nth Mcp_transport_protocol.supported_protocol_versions 1 in
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
  | Error (Mcp_client.Rpc { code; message }) ->
      check Alcotest.int "code" (-32602) code;
      check str "message" "unknown tool" message
  | Error err ->
      Alcotest.failf "read a JSON-RPC error as something else: %s"
        (Mcp_client.error_to_string err)
  | Ok _ -> Alcotest.fail "a JSON-RPC error was read as a result"

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
        ] );
      ( "tools",
        [ Alcotest.test_case "tools come back with their schemas" `Quick
            test_tools_come_back_with_their_schemas;
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
          Alcotest.test_case "a block that is not text is named" `Quick
            test_a_block_that_is_not_text_is_named;
        ] );
    ]
