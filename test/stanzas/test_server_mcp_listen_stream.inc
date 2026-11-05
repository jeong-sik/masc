; MCP subscriptions/listen over HTTP/1.1 (RFC-0493 §3.2), on in-memory httpun
; connections: the acknowledgement comes first and notifications follow, and a
; client that stops reading holds up no other subscription and ends at the
; stall bound.

(test
 (name test_server_mcp_listen_stream)
 (modules test_server_mcp_listen_stream)
 (libraries masc_server masc.mcp_transport_protocol alcotest eio eio.mock httpun bigstringaf str))
