# Sampling response contract repair

Inherited release blocker: [41031 review comment5971413395](https://github.com/jeong-sik/masc/pull/41031#issuecomment-5971413395) reports21 native worker tests with1 failure on fd7e6c37 and12c7. That native reproduction belongs to the reviewer; this coding session did not run Dune.

Independent source diagnosis found two defects: `package_response` contradicted its existing `.mli` metadata-stripping contract, and the failing assertion read an inline `response` absent by design. `addons/fusion-compute/server.py` enforces error keys exactly status/evidence; exposing a raw response inline would violate the actual consumer contract.

The repair selectively adapts #40991's metadata and bounded-outcome changes. Success exposes only host-owned sampling references. The raw callback remains private evidence. When encoding or response-reference overhead exceeds the package bound, the recorded classification and identity match the returned failure. For metadata overflow, the original answer remains in the invalid-response record whenever that bounded record fits; only oversized evidence falls back to a diagnostic. Current Store APIs and cancellation protection remain.

Worker assertions now check the actual selected host receipt's sanitized terminal.response, exact inline error keys, preserved raw metadata, and agreement between callback and retained overflow status. HTTP fixture provider/host assertions read private retained metadata; package metadata is checked independently. This is not a wholesale import of #40991 or its dependencies.

Validation: all3 changed OCaml files parsed; diff whitespace check passed. Existing Python Fusion compute consumer fixtures passed34 tests in9.435s (log retained). They exercise the package's existing stdio/error contract with a synthetic host, not the changed native broker. Native worker/HTTP execution, typechecking and final integrated FullRC remain unverified.

Independent source reviewer release_merge_review found and we corrected one P2: metadata overflow must retain an original answer that fits. Final3-file source PASS found no remaining P0-P2. Source review does not substitute for native/fullRC evidence.
