; #37435 — [models.<id>.capabilities] keys carry exact TOML presence: an
; unwritten capability key takes the provider wire's preset, an unwritten
; media key stays false because media input is fail-closed.

(test
 (name test_model_capability_presence)
 (modules test_model_capability_presence)
 (libraries masc_test_deps))
