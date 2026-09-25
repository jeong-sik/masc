(test
 (name test_runtime_muse_msp)
 (modules test_runtime_muse_msp)
 (deps
  (glob_files fixtures/muse_msp/*.ndjson))
 (libraries masc_test_deps))
