(test
 (name test_tui_execute_stream_http)
 (modules test_tui_execute_stream_http)
 (libraries alcotest masc masc_server masc_tui_loader masc_test_deps masc.dashboard masc.http_client masc.string_util masc.sse_wire eio eio_main unix httpun gluten uri))
