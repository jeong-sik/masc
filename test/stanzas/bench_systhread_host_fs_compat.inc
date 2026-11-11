; Not a test: prints how late a fiber of the calling domain wakes while other
; fibers of that domain run durable rewrites through Fs_compat, with their
; system threads on the calling domain or on Systhread_host's
; (RFC main-domain-scheduler-latency 7.6). Run by hand from _build/default/test.

(executable
 (name bench_systhread_host_fs_compat)
 (modules bench_systhread_host_fs_compat)
 (libraries masc.masc_core masc.fs_compat yojson eio eio_main unix threads.posix))
