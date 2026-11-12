; The login routes over the server's HTTP/1 router (plan C3-8c): a browser's
; requests as bytes to a router holding Server_login_http's routes over a zone
; on real files. The test plays GitHub through the routes' transport functions;
; no network. It checks the cookies, the origin, the form, the query and the
; body bound the server reads, what it writes (two set-cookie lines, the
; content length), the route table, and the query credential check of
; Server_auth. The MCP endpoint of a person (plan S1b-1a) is driven the same
; way, with a PAT and with a browser session.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_server_login_http)
 (modules test_server_login_http)
 (libraries masc_test_deps account_page_reading masc.mcp_transport_protocol digestif ptime))
