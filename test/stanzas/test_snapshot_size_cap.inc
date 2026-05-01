; Gen7 persistence-layer guard: cap_snapshot bounds string/list
; growth before continuity_summary is rendered + persisted. Stops
; monotonic growth when the LLM produces ever-longer [STATE] blocks.

(test
 (name test_snapshot_size_cap)
 (modules test_snapshot_size_cap)
 (libraries masc_test_deps))
