; Not a test: prints how late a fiber of the calling domain wakes while other
; fibers of that domain start children through Posix_spawn_process_mgr, with
; the spawn call's thread on the calling domain or on Systhread_host's
; (RFC main-domain-scheduler-latency 7.6). Run by hand from _build/default/test.

(executable
 (name bench_systhread_host_spawn)
 (modules bench_systhread_host_spawn)
 (libraries masc.masc_core masc.masc_process eio eio_main unix threads.posix))
