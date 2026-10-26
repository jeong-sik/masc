(test
 (name test_fs_exclusive_create_crash)
 (modules test_fs_exclusive_create_crash)
 (libraries alcotest fs_compat fs_compat_test_support fs_compat_internal eio eio_main eio.unix unix))
