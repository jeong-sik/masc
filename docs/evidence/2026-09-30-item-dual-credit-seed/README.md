# Item dual credit seed repair

Reviewed source: `7e5bf83427ce94829e3c5399df18c09bcb4a2d46`.

Combining the current restart fixture with the paid purchase scenario previously
copied the free Keeper 100-milli credit and then overwrote it with the paid
Keeper 700-milli credit. The free balance assertions still required 100.

The repair stores both canonical Paid rows, saves the combined seed artifact,
and compares both original payment rows after purchase and restart. They have
separate Goal identities and recipients. The paid purchase remains 700 → 500
for a 200-milli crown; the free scenario remains at 100.

The actual fixture-copy and seed statements from the acceptance script were
executed once in a temporary workspace. Both Paid rows were present and the
seed artifact matched the workspace ledger. `receipt.json` records their
combined hash and fixture hashes. Python syntax and JavaScript syntax passed.

This proves seed preparation only. Native HTTP, browser, purchase and restart
execution on this repaired head remain unverified. No build or CI was started.
