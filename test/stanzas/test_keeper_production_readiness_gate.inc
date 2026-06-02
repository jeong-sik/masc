(rule
 (alias runtest)
 (deps test_keeper_production_readiness_gate.py
       ../scripts/keeper-production-readiness-gate.py)
 (action (run python3 test_keeper_production_readiness_gate.py)))
