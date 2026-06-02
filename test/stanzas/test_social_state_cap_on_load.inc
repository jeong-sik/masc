; Gen12 load-path guard: checkpoint JSON deserialization also
; truncates narrative fields so pre-Gen8 snapshots do not
; reintroduce unbounded strings into meta.runtime.

(test
 (name test_social_state_cap_on_load)
 (modules test_social_state_cap_on_load)
 (libraries masc_test_deps))
