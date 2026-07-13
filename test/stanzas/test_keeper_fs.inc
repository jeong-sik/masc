(test
 (name test_keeper_fs)
 (modules test_keeper_fs)
 (libraries masc alcotest yojson unix eio eio_main))

(test
 (name test_keeper_fs_directory_durability)
 (modules test_keeper_fs_directory_durability)
 (libraries masc_test_deps))

(test
 (name test_keeper_fs_systhread_cancellation)
 (modules test_keeper_fs_systhread_cancellation)
 (libraries masc_test_deps))
