# Viewer TRPG unavailable boundary

Refs #26362. Base main3cce9a517b25863c00b48cfb3dd79b994ebc1044.

## Current contract and implementation

The issue's2026-09-30 acceptance explicitly permits retiring the selectable surface or reporting unavailable, and does not require restoring SSE or inventing a TRPG server. Current lib/server and bin have no /api/v1/trpg producer. The selectable viewer card, query mode and restored last mode could still enter TRPG, starting JSON polling, initial-state fetch and round execution against unsupported endpoints.

A closed ModeUnavailable::TrpgProducerAbsent result now rejects that known mode at the single transition boundary before DOM mode/title, URL, saved mode or NextState effects. The disabled card retains a visible reason; query and restored-storage requests publish the typed unavailable code and status text while staying Home. A later supported mode clears the notice and enters its normal ECS panel. Existing domain/render code remains inert behind state entry. Renamed polling plugin/setup/teardown describe the actual transport; unused EventSource dependency and tests for removed endpoint constructors are removed rather than reintroducing compatibility APIs. Redaction still tests the current generic SSE URL.

## Defined selected verification

Only suite:test/test_viewer_trpg_unavailable. The Python action builds the actual viewer dev WASM artifact, installs the CLI version bound by Cargo.lock, and runs actual Chrome against the candidate HTML and compiled module. Separate fresh browser profiles exercise ?mode=trpg and saved trpg mode. Success requires the Rust-published unavailable code, completed WASM boot, visible status/disabled card, original query/storage unchanged, Home state and zero TRPG fetch/EventSource requests. It then clicks the actual Monitor card and waits for its ECS OnEnter panel activation plus cleared notice; this proves accepted navigation, not a working Monitor backend. A timed dump without the actual marker fails. The WASM artifact digest and actual observed fields are printed.

The selected alias uses the existing Test workflow and runner; it adds no periodic or broad build. Cold Cargo compilation and matching wasm-bindgen CLI installation must fit the existing600s selected-suite guard. Feasibility has not been measured and is not a success claim. The artifact is dev/debug=0, not a release or installed viewer.

## Observed checks and limits

Locked cargo metadata succeeds, Python syntax compiles, changed Rust sources parse through rustfmt emit-stdout, and committed whitespace passes. Whole-tree cargo fmt reports pre-existing formatting differences; no unrelated files were reformatted. No local Dune, Rust/WASM build, typecheck, Chrome behavior or selected execution has been claimed. Full regression unrun. Independent adversarial source review passed predecessor5a433245; current recovery check additionally waits for the actual Monitor ECS panel. Both independent source sessions passed feature head ec30b1e61e0140de57daadf292d5433f81374f82. The final documentation/changelog head and selected execution must be recorded separately.

Native stack init adopted this own branch; submit refused “Stacked PRs are not enabled for this repository”. No native membership, merge, installation, provider or whole-issue completion is inferred. #26362 remains OPEN until the actual viewer/WASM evidence and integration are established.
