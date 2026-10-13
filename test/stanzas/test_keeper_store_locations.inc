; Which folder each keeper store accessor opens.

(test
 (name test_keeper_store_locations)
 (modules test_keeper_store_locations)
 (libraries alcotest masc masc_workspace dated_jsonl fs_compat eio eio_main unix))
