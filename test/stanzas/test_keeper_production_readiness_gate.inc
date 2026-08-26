(rule
 (alias runtest)
 (deps test_keeper_production_readiness_gate.py
       ../scripts/keeper-production-readiness-gate.py
       ; Same sandbox gap as the fleet-readiness stanza.
       ../scripts/lib/keeper_store_layout.py
       ; The layout manifest is an executable the script runs. Naming the
       ; library alone put the reader in the sandbox and left the thing it
       ; reads outside it, so the suite raised StoreLayoutUnavailable before
       ; its first assertion -- and a (rule ...) failure named no suite, so
       ; the report dropped it whenever anything else was red.
       ../bin/keeper_store_layout_manifest.exe)
 (action
  (setenv KEEPER_STORE_LAYOUT_MANIFEST_EXE
   %{dep:../bin/keeper_store_layout_manifest.exe}
   (run python3 test_keeper_production_readiness_gate.py))))
