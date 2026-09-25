(test
 (name test_runtime_muse_msp)
 (modules test_runtime_muse_msp)
 (deps
  fixtures/muse_msp/approval-round-trip.ndjson
  fixtures/muse_msp/handshake-liststream-granted.ndjson
  fixtures/muse_msp/provider-failure-turn.ndjson
  fixtures/muse_msp/text-run-single-turn.ndjson
  fixtures/muse_msp/tolerance-unknown-item-kind.ndjson)
 (libraries masc_test_deps))
