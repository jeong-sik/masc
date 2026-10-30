(test
 (name test_safe_ops_read_json_eio)
 (modules test_safe_ops_read_json_eio)
 (libraries alcotest masc_core eio eio_main fs_compat yojson unix))
