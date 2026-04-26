(** Tests for Streamable HTTP Transport *)

module SH = Masc_mcp.Streamable_http

let test_session_create () =
  let session = SH.Session.create ~transport:SH.Streamable_HTTP in
  Alcotest.(check bool) "session id not empty" true (String.length session.id > 0);
  Alcotest.(check bool) "session id is UUID format" true (String.contains session.id '-');
  Alcotest.(check int) "subscriptions empty" 0 (List.length session.subscriptions)
;;

let test_session_find () =
  let session = SH.Session.create ~transport:SH.Streamable_HTTP in
  let found = SH.Session.find session.id in
  Alcotest.(check bool) "session found" true (Option.is_some found);
  let not_found = SH.Session.find "nonexistent-id" in
  Alcotest.(check bool) "nonexistent not found" true (Option.is_none not_found)
;;

let test_session_touch () =
  let session = SH.Session.create ~transport:SH.Streamable_HTTP in
  let old_time = session.last_seen in
  Time_compat.sleep 0.01;
  SH.Session.touch session;
  Alcotest.(check bool) "last_seen updated" true (session.last_seen > old_time)
;;

let test_session_cleanup () =
  (* Create a session that will expire immediately *)
  let _session = SH.Session.create ~transport:SH.Streamable_HTTP in
  Time_compat.sleep 0.01;
  let removed = SH.Session.cleanup ~ttl_seconds:0.001 in
  Alcotest.(check bool) "at least one session cleaned" true (removed >= 1)
;;

let test_handle_post_valid_json () =
  let body = {|{"jsonrpc":"2.0","method":"test","id":1}|} in
  let response, _session = SH.handle_post ~body () in
  match response with
  | SH.Json_response json ->
    let json_str = Yojson.Safe.to_string json in
    let has_jsonrpc =
      try
        let _ = Yojson.Safe.from_string json_str in
        let re = Str.regexp_string "jsonrpc" in
        Str.search_forward re json_str 0 >= 0
      with
      | _ -> false
    in
    Alcotest.(check bool) "contains jsonrpc" true has_jsonrpc
  | _ -> Alcotest.fail "expected Json_response"
;;

let test_handle_post_invalid_json () =
  let body = "not valid json" in
  let response, _session = SH.handle_post ~body () in
  match response with
  | SH.Error_response (code, _msg) -> Alcotest.(check int) "400 error" 400 code
  | _ -> Alcotest.fail "expected Error_response"
;;

let test_handle_post_batch () =
  let body =
    {|[{"jsonrpc":"2.0","method":"a","id":1},{"jsonrpc":"2.0","method":"b","id":2}]|}
  in
  let response, _session = SH.handle_post ~body () in
  match response with
  | SH.Error_response (code, message) ->
    Alcotest.(check int) "400 error" 400 code;
    Alcotest.(check bool)
      "mentions batch unsupported"
      true
      (String.length message > 0 && String.contains message 'b')
  | _ -> Alcotest.fail "expected Error_response"
;;

let test_handle_post_handler_dispatch () =
  let called = ref 0 in
  let handler (req : Yojson.Safe.t) =
    incr called;
    match req with
    | `Assoc _ ->
      let id = `Int 99 in
      `Assoc [ "jsonrpc", `String "2.0"; "id", id; "result", `Assoc [ "ok", `Bool true ] ]
    | _ -> `Null
  in
  let body = {|{"jsonrpc":"2.0","method":"ping","id":99}|} in
  let response, _session = SH.handle_post ~body ~request_handler:handler () in
  Alcotest.(check int) "handler called once" 1 !called;
  match response with
  | SH.Json_response json ->
    let json_str = Yojson.Safe.to_string json in
    Alcotest.(check bool) "handler result returned" true (String.length json_str > 0)
  | _ -> Alcotest.fail "expected Json_response"
;;

let test_handle_get () =
  match SH.handle_get () with
  | Ok session ->
    Alcotest.(check bool) "session created" true (String.length session.id > 0)
  | Error _ -> Alcotest.fail "expected Ok"
;;

let test_with_session_header () =
  let session = SH.Session.create ~transport:SH.Streamable_HTTP in
  let headers = SH.with_session_header session [] in
  Alcotest.(check int) "one header added" 1 (List.length headers);
  let key, value = List.hd headers in
  Alcotest.(check string) "header key" "mcp-session-id" key;
  Alcotest.(check string) "header value" session.id value
;;

let () =
  (* Initialize RNG for session ID generation *)
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Alcotest.run
    "Streamable HTTP"
    [ ( "Session"
      , [ Alcotest.test_case "create" `Quick test_session_create
        ; Alcotest.test_case "find" `Quick test_session_find
        ; Alcotest.test_case "touch" `Quick test_session_touch
        ; Alcotest.test_case "cleanup" `Quick test_session_cleanup
        ] )
    ; ( "Handle POST"
      , [ Alcotest.test_case "valid json" `Quick test_handle_post_valid_json
        ; Alcotest.test_case "invalid json" `Quick test_handle_post_invalid_json
        ; Alcotest.test_case "batch" `Quick test_handle_post_batch
        ; Alcotest.test_case "handler dispatch" `Quick test_handle_post_handler_dispatch
        ] )
    ; "Handle GET", [ Alcotest.test_case "create session" `Quick test_handle_get ]
    ; ( "Headers"
      , [ Alcotest.test_case "with_session_header" `Quick test_with_session_header ] )
    ]
;;
