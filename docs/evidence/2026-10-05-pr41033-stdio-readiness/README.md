# PR #41033 stdio readiness response

Base: `448e0e059941105bdcd055ab9a21002e0378cf8e`. Move the existing sampling recovery attempt from the HTTP composition root into shared `activate_owner_state`; preserve warning-and-continue error semantics. Both HTTP and stdio await activation before readiness, and HTTP also waits before exposing its server state. The shared timing observer now records recovery begin/end.

Actual focused wrapper build: `DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_lane_addon.exe bin/main_stdio_eio.exe` PASS. The stdio executable linked; it was not launched.

Actual existing journal regression: `test_lane_addon.exe test 'optional extension' 0` with test/dune declared environment, **1 PASS / 21 SKIP in 6.828s**. This case covers both journal namespaces, ordering, existing/fallback/corrupt/oversized/obstructed blobs, escaped records and damaged sibling isolation using real retained journals. It tests recovery behavior, not a complete stdio process. No whole bootstrap execution or whole suite claim.

`check-source-order.py` is an evidence-only source assertion, not a native test or an AST policy gate. Published source fails the shared-activation recovery assertion; repaired source passes all six explicit ordering checks. Its result is not runtime RED/GREEN. Raw results and exact source/binary hashes are in `checks.json`.

The separate P1 full-history maintenance rescan remains OPEN. No cache, dirty index or transaction protocol was added. Parent #40960 response still needs integration before publication.
