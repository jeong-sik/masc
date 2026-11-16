; Not a test: prints what Os_mutex.protect costs next to Mutex.protect, for
; an empty section and for the section of a queued log line (RFC
; a-fiber-that-suspends-while-holding-an-os-mutex-fails-at-unlock §6.1 case
; 12). The Os_mutex workflow runs it; it also runs by hand from
; _build/default/test.

(executable
 (name bench_os_mutex_cost)
 (modules bench_os_mutex_cost)
 (libraries masc.agent_core.os_mutex eio eio_posix yojson unix))
