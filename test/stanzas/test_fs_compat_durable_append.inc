(test
 (name test_fs_compat_durable_append)
 (modules test_fs_compat_durable_append)
 (libraries fs_compat alcotest eio eio_main unix))

(executable
 (name bench_private_jsonl_stable_lock)
 (modules bench_private_jsonl_stable_lock)
 (libraries fs_compat mtime mtime.clock.os unix))
