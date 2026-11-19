; A tools/call POST for a streaming tool over the real HTTP/1 route.

(test
 (name test_mcp_post_sse_stream)
 (modules test_mcp_post_sse_stream)
 (libraries alcotest masc masc_server masc_test_deps masc.http_client masc.string_util eio eio_main httpun gluten yojson))
