(test
 (name test_tool_metrics_store_concurrent)
 (modules test_tool_metrics_store_concurrent)
 (libraries masc_test_deps masc.tool_metrics_store masc.tool_types alcotest eio eio_main unix))
