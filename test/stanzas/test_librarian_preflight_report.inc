(rule
 (alias runtest-test_librarian_preflight_report)
 (deps test_librarian_preflight_report.py ../scripts/librarian/compare-preflight.py)
 (action (run python3 %{dep:test_librarian_preflight_report.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_librarian_preflight_report)))
