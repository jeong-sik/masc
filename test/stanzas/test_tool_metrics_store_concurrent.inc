(test
 (name test_tool_metrics_store_concurrent)
 (modules test_tool_metrics_store_concurrent)
 (libraries masc_test_deps masc masc.tool_metrics_store alcotest eio eio.unix eio_main unix))
