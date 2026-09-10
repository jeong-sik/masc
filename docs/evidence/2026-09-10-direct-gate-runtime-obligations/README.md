# Simultaneous Gate and runtime retry

An attempt can create a new durable Gate request and then exhaust its current runtime. The runtime-error branch previously bypassed Gate suspension, losing the new approval identity from the operation journal. A Gate wait now carries the frozen runtime retry as a simultaneous obligation. Both must reference the same exact checkpoint, and the transaction retains the original input.

The Owner cannot claim this request while its Gate resolution is absent. Once the authoritative resolution is admitted, the direct turn restores the original frozen runtime assignment and successor suffix, rather than resolving a fresh default lane. Existing replay evidence admission and checkpoint continuation remain in use.

Added store coverage checks restart, full original input, refusal of a different checkpoint, pending nonclaimability and retained effect identity. The production Gate fixture also checks the frozen runtime assignment and candidate suffix across approval. Source parsing and diff checks passed; no local build. CI and live model proof are still pending.

Source-binding and checkpoint-retention failure reconciliation are separate boundaries. Their unresolved-binding representation must retain the frozen runtime suffix even when no checkpoint can be confirmed; this change does not claim that combined failure case is proven.
