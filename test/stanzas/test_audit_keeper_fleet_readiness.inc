(rule
 (alias runtest)
 (deps test_audit_keeper_fleet_readiness.py
       ../scripts/audit-keeper-fleet-readiness.py
       ; The script reaches scripts/lib via sys.path, which names a
       ; directory but does not put the file in dune's sandbox.
       ../scripts/lib/keeper_store_layout.py)
 (action (run python3 test_audit_keeper_fleet_readiness.py)))
