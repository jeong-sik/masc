(rule
 (alias runtest)
 (deps test_keeper_production_readiness_gate.py
       ../scripts/keeper-production-readiness-gate.py
       ; Same sandbox gap as the fleet-readiness stanza.
       ../scripts/lib/keeper_store_layout.py)
 (action (run python3 test_keeper_production_readiness_gate.py)))
