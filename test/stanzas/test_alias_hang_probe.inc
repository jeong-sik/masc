(rule
 (alias runtest-test_alias_hang_probe)
 (deps test_alias_hang_probe.py)
 (action (run python3 test_alias_hang_probe.py)))

(alias (name runtest) (deps (alias runtest-test_alias_hang_probe)))
