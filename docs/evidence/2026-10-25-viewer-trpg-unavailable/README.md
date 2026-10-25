# Viewer TRPG unavailable boundary

Refs #26362. Authoring base main3cce9a517b25863c00b48cfb3dd79b994ebc1044; restacked base6f28acccdc73822004da5bb486fc6136a4a86c74.

## Current contract and implementation

The issue's2026-09-30 acceptance explicitly permits retiring the selectable surface or reporting unavailable, and does not require restoring SSE or inventing a TRPG server. Current lib/server and bin have no /api/v1/trpg producer. The selectable viewer card, query mode and restored last mode could still enter TRPG, starting JSON polling, initial-state fetch and round execution against unsupported endpoints.

A closed ModeUnavailable::TrpgProducerAbsent result now rejects that known mode at the single transition boundary before DOM mode/title, URL, saved mode or NextState effects. The disabled card retains a visible reason; query and restored-storage requests publish the typed unavailable code and status text while staying Home. A later supported mode clears the notice and enters its normal ECS panel. Existing domain/render code remains inert behind state entry. Renamed polling plugin/setup/teardown describe the actual transport; unused EventSource dependency and tests for removed endpoint constructors are removed rather than reintroducing compatibility APIs. Redaction still tests the current generic SSE URL.

## Defined selected verification

Only suite:test/test_viewer_trpg_unavailable. The Python action builds the actual viewer dev WASM artifact, installs the CLI version bound by Cargo.lock, and runs actual Chrome against the candidate HTML and compiled module. Separate fresh browser profiles exercise ?mode=trpg and saved trpg mode. Success requires the Rust-published unavailable code, completed WASM boot, visible status/disabled card, original query/storage unchanged, Home state and zero TRPG fetch/EventSource requests. It then clicks the actual Monitor card and waits for its ECS OnEnter panel activation plus cleared notice; this proves accepted navigation, not a working Monitor backend. A timed dump without the actual marker fails. The WASM artifact digest and actual observed fields are printed.

The selected alias uses the existing Test workflow and runner; it adds no periodic or broad build. Cold Cargo compilation and matching wasm-bindgen CLI installation must fit the existing600s selected-suite guard. Actual requested execution is recorded below; the initial budget feasibility was unmeasured when authored. The artifact is dev/debug=0, not a release or installed viewer.

## Observed checks and limits

Locked cargo metadata succeeds, Python syntax compiles, changed Rust sources parse through rustfmt emit-stdout, and committed whitespace passes. Whole-tree cargo fmt reports pre-existing formatting differences; no unrelated files were reformatted. No local Dune, Rust/WASM build or typecheck was run. Actual CI compilation and Chrome behavior are recorded below. Full regression unrun. Independent adversarial source review passed predecessor5a433245; current recovery check additionally waits for the actual Monitor ECS panel. Both independent source sessions passed feature head ec30b1e61e0140de57daadf292d5433f81374f82. The final documentation/changelog head and selected execution must be recorded separately.

Native stack init adopted this own branch; submit refused “Stacked PRs are not enabled for this repository”. No native membership, merge, installation, provider or whole-issue completion is inferred. #26362 remains OPEN until the actual viewer/WASM evidence and integration are established.

## Restack and requested execution

During review main advanced through unrelated Cohere, MCP, dashboard/metadata and prompt recovery changes. gh stack rebase fetched origin/main6f28accc and preserved the dirty original main worktree. The one-layer stack had an end-of-file test/dune conflict; both the incoming prompt mutation recovery include and this viewer alias were retained. Nine Viewer/Python inputs are unchanged; source-sha256.txt refreshes the whole test/dune blob, whose unrelated include advanced. This is not a new behavior change or a fabricated execution.

Run40182013461 was requested for predecessor d20baab64c20bc4552e0690a4399e1df97ecc8aa with only test/test_viewer_trpg_unavailable. Its actual completed result is recorded below. The restack does not replace/cancel that live request or imply a new run at the rebased head. Actual candidate identities and result must be read separately. Full regression unrun.

## Actual selected WASM/Chrome execution

Run40182013461 completed SUCCESS at d20baab64c20bc4552e0690a4399e1df97ecc8aa. Actual checkout, Cargo dev completion, installed matching wasm-bindgen0.2.108, both VIEWER_WASM_OBSERVED records and the final receipt were read. The viewer artifact compiled in1m23s; matching CLI preparation and the two Chrome cases completed within the existing600s alias guard. No narrower fixture or empty test selection replaces the WASM build.

Both actual query and stored-mode cases booted compiled WASM, showed Rust-published trpg_producer_absent, remained mode-home, retained the original query/storage values and displayed a disabled card/status. Before recovery the sole fetch was the actual viewer_bg.wasm. After clicking Monitor, its ECS OnEnter panel activated and the unavailable status cleared; the only additional observed request was /mcp, never /api/v1/trpg/. This proves supported navigation, not an actual MASC backend connection. The artifact is dev/debug=0 with digest9ad65385b8cde2ea1ee2e810fef7b90aacf136c22fe21c5ed24b657336505b25, not a release/install result. Actual raw output and decoded results are preserved alongside this README.

The nine Viewer/Python source inputs remain byte-identical after restack. The tenth whole-Dune hash changed only to preserve the incoming unrelated prompt recovery include; the selected viewer alias/action is unchanged. The earlier run is not relabeled as a new execution at the restacked or later documentation head. Full regression, native viewer, release/installation and integration remain unproved. #26362 stays OPEN pending integration.
