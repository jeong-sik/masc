; RFC-eliminate-substring-destructive-classifier Phase 1 — legacy substring
; destructive classifier vs the typed
; Shell IR keeper gate (autonomous overlay). Differential-safety harness:
; measures the gap (substring blocks / typed-autonomous allows) and ratchets
; it via a baseline so it cannot grow silently. Read-only, deterministic.
(test
 (name test_destructive_floor_differential)
 (modules test_destructive_floor_differential)
 (libraries masc_test_deps))
