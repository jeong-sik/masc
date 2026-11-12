; Not a test: prints how late a fiber of the calling domain wakes while other
; fibers of that domain hand JSON parsing and encoding to Systhread_host.run,
; with the work's thread on the calling domain or on the host's
; (RFC main-domain-scheduler-latency 7.6). Run by hand from _build/default/test.

(executable
 (name bench_systhread_cpu_work)
 (modules bench_systhread_cpu_work)
 (libraries masc.masc_core eio eio_main yojson unix threads.posix))
