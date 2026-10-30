(** MCP auth reject boundary observability.

    2026-08-18 live finding: after a token rotation every external MCP
    credential was stale and every client request died at the auth
    boundary with a client-only 401 — no log line, no metric, empty
    session store. These tests pin the reject-boundary contract:

      1. [record_mcp_auth_reject] advances
         [masc_mcp_auth_rejects_total{endpoint,reason}] with the typed
         [auth_error_code] as [reason].
      2. A failure without [auth_error_code] lands on the bounded
         fallback label ["unclassified"], never on message text.
      3. [mcp_auth_reject_details] carries endpoint / reason /
         claimed_agent / token_presented / session_id and never the
         bearer itself; absent session folds to [`Null], not [""]. *)

module Respond = Server_mcp_transport_http_respond
module Types = Server_mcp_transport_http_types
module Metrics = Masc.Otel_metric_store

let reject_total ~endpoint ~reason =
  Metrics.metric_value_or_zero
    Metrics.metric_mcp_auth_rejects
    ~labels:[ ("endpoint", endpoint); ("reason", reason) ]
    ()

let failure ?auth_error_code message : Types.auth_failure =
  { message; auth_error_code }

let test_reject_counts_with_typed_reason () =
  let endpoint = "POST /mcp (test-typed)" in
  let before = reject_total ~endpoint ~reason:"invalid_token" in
  Respond.record_mcp_auth_reject ~endpoint ~claimed_agent:(Some "probe-agent")
    ~token_presented:true ~session_id:(Some "mcp_test_session")
    (failure ~auth_error_code:"invalid_token" "Invalid token: Token mismatch");
  Alcotest.(check (float 0.0001))
    "reject counted under typed reason" (before +. 1.0)
    (reject_total ~endpoint ~reason:"invalid_token")

let test_reject_without_code_uses_bounded_fallback () =
  let endpoint = "GET /mcp (test-fallback)" in
  let before = reject_total ~endpoint ~reason:"unclassified" in
  Respond.record_mcp_auth_reject ~endpoint ~claimed_agent:None
    ~token_presented:false ~session_id:None
    (failure "Authentication required. Use 'Authorization: Bearer <token>'.");
  Alcotest.(check (float 0.0001))
    "no auth_error_code -> unclassified label" (before +. 1.0)
    (reject_total ~endpoint ~reason:"unclassified");
  Alcotest.(check (float 0.0001))
    "message text never becomes a label" 0.0
    (reject_total ~endpoint
       ~reason:"Authentication required. Use 'Authorization: Bearer <token>'.")

let member name = function
  | `Assoc fields -> List.assoc name fields
  | _ -> Alcotest.fail "details payload is not an object"

let test_details_payload_shape () =
  let details =
    Respond.mcp_auth_reject_details ~endpoint:"DELETE /mcp"
      ~claimed_agent:(Some "codex-mcp-client") ~token_presented:true
      ~session_id:(Some "mcp_abc")
      (failure ~auth_error_code:"invalid_token" "Invalid token: Token mismatch")
  in
  Alcotest.(check string)
    "endpoint" "DELETE /mcp"
    (match member "endpoint" details with
     | `String s -> s
     | _ -> Alcotest.fail "endpoint not a string");
  Alcotest.(check string)
    "reason mirrors auth_error_code" "invalid_token"
    (match member "reason" details with
     | `String s -> s
     | _ -> Alcotest.fail "reason not a string");
  Alcotest.(check string)
    "claimed_agent" "codex-mcp-client"
    (match member "claimed_agent" details with
     | `String s -> s
     | _ -> Alcotest.fail "claimed_agent not a string");
  Alcotest.(check bool)
    "token_presented" true
    (match member "token_presented" details with
     | `Bool b -> b
     | _ -> Alcotest.fail "token_presented not a bool")

let test_details_absent_session_is_null () =
  let details =
    Respond.mcp_auth_reject_details ~endpoint:"h2 DELETE /mcp"
      ~claimed_agent:None ~token_presented:false ~session_id:None
      (failure "missing token")
  in
  (match member "session_id" details with
   | `Null -> ()
   | other ->
       Alcotest.failf "absent session must be `Null, got %s"
         (Yojson.Safe.to_string other));
  match member "reason" details with
  | `Null -> ()
  | other ->
      Alcotest.failf "absent auth_error_code must be `Null, got %s"
        (Yojson.Safe.to_string other)

let test_non_tool_bodies_skip_actor_resolution () =
  let open Alcotest in
  Eio_main.run @@ fun _env ->
  let headers = Httpun.Headers.of_list [ ("authorization", "Basic invalid") ] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let labels = [ ("outcome", "error"); ("err_kind", "unauthorized") ] in
  let fallback_count () =
    Metrics.metric_value_or_zero
      Metrics.metric_silent_dashboard_actor_fallback ~labels ()
  in
  let before = fallback_count () in
  List.iter
    (fun body ->
      let result =
        Server_mcp_transport_http.body_with_canonical_http_actor
          ~base_path:(Filename.get_temp_dir_name ()) ~auth_token:None request body
      in
      check bool "unmodified body is reused" true (result == body))
    [ {|{ "jsonrpc": "2.0", "method": "ping", "id": 1 }|};
      {|{"jsonrpc":"2.0","method":"tools/list","id":2}|};
      {|{"jsonrpc":"2.0","method":"initialize","id":3}|};
      {|{"jsonrpc":"2.0","method":"notifications/initialized"}|};
      {|{"jsonrpc":"2.0","method":42,"id":4}|};
      "invalid json" ];
  check (float 0.0) "no actor-resolution fallback for non-tool bodies"
    before (fallback_count ());
  (* Positive control: the same credential reaches the real resolver for a
     tools/call notification too; lack of an id must not skip injection. *)
  ignore
    (Server_mcp_transport_http.body_with_canonical_http_actor
       ~base_path:(Filename.get_temp_dir_name ()) ~auth_token:None request
       {|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_status","arguments":{}}}|});
  check (float 0.0) "tool call still resolves actor"
    (before +. 1.0) (fallback_count ())

let () =
  Alcotest.run "mcp_auth_reject_observability"
    [
      ( "reject-boundary",
        [
          Alcotest.test_case "counter advances with typed reason" `Quick
            test_reject_counts_with_typed_reason;
          Alcotest.test_case "missing code -> unclassified label" `Quick
            test_reject_without_code_uses_bounded_fallback;
          Alcotest.test_case "details payload shape" `Quick
            test_details_payload_shape;
          Alcotest.test_case "absent session/code fold to null" `Quick
            test_details_absent_session_is_null;
          Alcotest.test_case "non-tool bodies skip actor resolution" `Quick
            test_non_tool_bodies_skip_actor_resolution;
        ] );
    ]
