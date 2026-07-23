(test
 (name test_hitl_summary_worker)
 (modules test_hitl_summary_worker)
 (libraries
  alcotest
  masc
  masc_test_deps
  compaction_exact_output_fixture
  eio_main
  unix))
