# Package routing on the current parent chain

Actual candidate `253806288eecd560e9d932b6938265a843794fd2` composes the H2 catalog/preview and active-worktree fixes through #41208 after the published Browser/Machine chain. Focused build and all9 H2 request-body/admission cases passed against the real gateway with in-memory H2 frames. Auth refusal, accepted-token payloads, duplicate/unknown query refusal and actual linked-Git-worktree discovery/preview containment are exercised. This is not network h2c negotiation or new H1 wire coverage.

Command from the qualified isolated root: `opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build test/test_h2_request_body_admission.exe`; then from `test/`, `../_build/default/test/test_h2_request_body_admission.exe` with MASC_BASE_PATH, ZAI_API_KEY and TYPESAFEAI_API_KEY empty, and DUNE_SOURCEROOT set to that root.

Raw build/test logs are byte-exact. Source and binary hashes are recorded. Independent source review verified the same four repaired source blobs as owner452ee31afa730aea1d823f9737bd52d3b1461a9d and all three integration ancestries. Earlier246 native/594 Web/Browser-Machine PTY evidence remains attached to candidate d35c75b0; it was not rerun or relabeled here. No full CI, formal approval, release, production or TerminalBench claim.
