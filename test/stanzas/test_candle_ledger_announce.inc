(test
 (name test_candle_ledger_announce)
 (modules test_candle_ledger_announce)
 (libraries alcotest eio eio_main unix masc masc.fs_compat masc.masc_core masc.masc_candle
  masc.masc_candle_store masc.masc_candle_runtime masc_server))
