(rule
 (alias runtest)
 (deps test_audit_keeper_fleet_readiness.py
       ../scripts/audit-keeper-fleet-readiness.py)
 (action (run python3 test_audit_keeper_fleet_readiness.py)))
