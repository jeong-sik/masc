(test
 (name test_hitl_summary_worker)
 (modules test_hitl_summary_worker)
 (libraries
  alcotest
  compaction_exact_output_fixture
  masc
  masc.runtime
  masc_test_deps
  eio_main))
