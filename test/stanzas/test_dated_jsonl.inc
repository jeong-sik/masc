(test
 (name test_dated_jsonl)
 (modules test_dated_jsonl)
 ; #27143: the prune boundary is asserted through the module that owns the
 ; day-file layout, not a second copy of the format
 (libraries dated_jsonl jsonl_writer fs_compat alcotest eio eio_main yojson unix))
