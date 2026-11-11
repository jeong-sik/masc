; A locked update of an append-only JSONL file reads only the rows after the
; cursor its caller kept.

(test
 (name test_fs_compat_update_after_cursor)
 (modules test_fs_compat_update_after_cursor)
 (libraries fs_compat alcotest unix))
