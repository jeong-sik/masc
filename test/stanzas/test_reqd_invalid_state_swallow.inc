; 2026-05-05 cycle9 FATAL regression guard.
; Checks that lib/http_server_eio.ml, bin/main_eio.ml,
; lib/server/server_mcp_transport_http_respond.ml,
; lib/server/server_mcp_transport_http.ml, and
; lib/server/server_ws_standalone.ml contain the defensive
; safe_respond_with_string / safe_reqd_respond / send_pong-guard
; patterns introduced to prevent Failure("httpun.Reqd.respond_with_string:
; invalid state, currently handling error") from escaping to the top-level
; handler and causing a server restart.

(test
 (name test_reqd_invalid_state_swallow)
 (modules test_reqd_invalid_state_swallow)
 (deps
  ../lib/http_server_eio.ml
  ../bin/main_eio.ml
  ../lib/server/server_mcp_transport_http_respond.ml
  ../lib/server/server_mcp_transport_http.ml
  ../lib/server/server_ws_standalone.ml))
