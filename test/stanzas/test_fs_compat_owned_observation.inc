(test
 (name test_fs_compat_owned_observation)
 (modules test_fs_compat_owned_observation owned_private_jsonl_cases)
 (libraries alcotest fs_compat eio eio_main unix))
