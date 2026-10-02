(test
 (name test_candle_ledger)
 (modules test_candle_ledger)
 (deps fixtures/item-http/candle.toml fixtures/item-http/restart-credit.jsonl
       fixtures/item-http/paid-credit.jsonl)
 (libraries yojson alcotest eio_main eio fs_compat masc_candle masc_candle_store masc_candle_config unix))
