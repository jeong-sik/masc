(** test_streamable_http_upgrade — RFC-0100 PR-3 auto-upgrade dispatch.

    Asserts the policy that gates the POST /mcp → SSE upgrade on the
    streaming-tools registry: tools listed in
    [Server_mcp_streaming_tools] receive SSE framing; tools outside
    the registry stay on the RFC-0100 PR-2 chunked-JSON shape. The
    full HTTP round-trip is covered by [test_mcp_post_sse_e2e.ml]
    (e2e, slow); these are pure unit assertions on the gate's input
    contract. *)

open Alcotest

module Streaming = Server_mcp_streaming_tools
module Http_transport = Server_mcp_transport_http

let tools_call_body ~tool_name =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":{}}}|}
    tool_name

let test_registry_membership_known_tools () =
  (* The hand-curated registry must include the tool the e2e suite exercises
     with SSE expectations (test_mcp_post_sse_e2e.ml: [masc_status]).
     Non-listed tools keep the chunked-JSON shape. *)
  check bool "masc_status in registry" true
    (Streaming.is_streaming_capable "masc_status")

let test_registry_excludes_other_tools () =
  (* Any tool not explicitly listed should not auto-upgrade. The
     specific names below are public MCP tools that have no streaming
     handler today; pinning them guards against an accidental
     [public_mcp_surface_tools]-wide enablement. *)
  check bool "masc_broadcast excluded" false
    (Streaming.is_streaming_capable "masc_broadcast");
  check bool "masc_bind excluded" false
    (Streaming.is_streaming_capable "masc_bind");
  check bool "masc_messages excluded" false
    (Streaming.is_streaming_capable "masc_messages");
  check bool "unknown tool name excluded" false
    (Streaming.is_streaming_capable "tool_that_does_not_exist")

let test_body_tools_call_name_extraction () =
  (* The gate parses [params.name] from a JSON-RPC tools/call body.
     Malformed bodies must return [None] — never trigger streaming. *)
  check (option string) "well-formed tools/call body"
    (Some "masc_status")
    (Http_transport.body_tools_call_name
       (tools_call_body ~tool_name:"masc_status"));
  check (option string) "missing params"
    None
    (Http_transport.body_tools_call_name
       {|{"jsonrpc":"2.0","id":1,"method":"tools/call"}|});
  check (option string) "missing name"
    None
    (Http_transport.body_tools_call_name
       {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}|});
  check (option string) "name not a string"
    None
    (Http_transport.body_tools_call_name
       {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":42}}|});
  check (option string) "malformed JSON"
    None
    (Http_transport.body_tools_call_name "not json at all");
  (match Http_transport.body_tools_call_name_result "not json at all" with
   | Error (Http_transport.Body_tools_call_name_parse_error message) ->
       check bool "malformed JSON detail present" true (String.length message > 0)
   | Ok _ -> fail "expected JSON parse error");
  check (result (option string) reject) "missing params result"
    (Ok None)
    (Http_transport.body_tools_call_name_result
       {|{"jsonrpc":"2.0","id":1,"method":"tools/call"}|});
  check (option string) "non-tools/call method"
    (Some "init")
    (* RFC-0100 PR-3 body parser is method-agnostic; the gate caller
       must verify method first via [body_jsonrpc_method]. We pin the
       agnostic behaviour so a future caller does not assume a
       built-in method check that does not exist. *)
    (Http_transport.body_tools_call_name
       {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"name":"init"}}|})

let () =
  Alcotest.run "test_streamable_http_upgrade"
    [
      ( "rfc-0100-pr3-streaming-registry",
        [
          test_case "registry includes known streaming tools" `Quick
            test_registry_membership_known_tools;
          test_case "registry excludes non-streaming tools" `Quick
            test_registry_excludes_other_tools;
          test_case "tools/call name extraction handles edge cases" `Quick
            test_body_tools_call_name_extraction;
        ] );
    ]
