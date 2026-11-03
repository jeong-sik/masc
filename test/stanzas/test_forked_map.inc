; Forked_map runs jobs in child processes and returns their results in job
; order. The cases fork real processes: order of results, a job that raises or
; dies, a result larger than a pipe, the limit on processes alive at once,
; buffered text not printed twice, and children ended with the caller.
;
; There is no (action ...) field, so the targeted CI runner builds the
; executable before the suite starts and only the run is under the timeout.

(test
 (name test_forked_map)
 (modules test_forked_map)
 (libraries alcotest masc.masc_process unix))
