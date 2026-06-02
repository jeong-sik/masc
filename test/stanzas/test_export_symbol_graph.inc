(rule
 (alias runtest)
 (deps test_export_symbol_graph.py
       ../scripts/ide/export-symbol-graph)
 (action (run python3 test_export_symbol_graph.py)))
