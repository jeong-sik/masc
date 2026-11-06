; Rows that reach a Keeper's queue while one of its turns runs. A row is listed
; to the running turn once, a request that failed lists it again, and no row is
; lost to the per-round limit.

(test
 (name test_keeper_arrived_stimuli)
 (modules test_keeper_arrived_stimuli)
 (libraries alcotest astring masc masc_test_deps))
