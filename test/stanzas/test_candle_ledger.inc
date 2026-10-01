(test
 (name test_candle_ledger)
 (modules test_candle_ledger)
 (deps fixtures/item-http/candle.toml fixtures/item-http/restart-credit.jsonl)
 (libraries masc_candle_config yojson alcotest eio_main eio fs_compat masc_candle masc_candle_store unix))
