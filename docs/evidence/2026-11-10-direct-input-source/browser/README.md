# #26049 request-source display evidence

The actual worktree `MemoryInspector` component, production API decoder and dashboard CSS were rendered in Ego Lite Chromium against a standalone synthetic HTTP backend at `http://127.0.0.1:5195/`.

Observed: the individual Keeper memory drawer displayed **요청 출처 · 113B**. The same synthetic HTTP TurnRecord contains `blocks[].block = direct_input_source` and `input_components[].component = prompt.direct_input_source`; the actual strict decoder accepted both. The visible composition legend uses the input-component data. Total synthetic content is 1,232B; synthetic serialized provider-request body is 1,343B. This does not assert real provider serialization or execution.

- `memory-inspector-source-raw.png`: unmodified 1548×990 browser capture, visually inspected. The requested legend row is fully on screen.
- `browser-dom.json`, `browser-snapshot.txt`: actual DOM, legend bounds, browser user-agent, navigation timing, API bodies/statuses and loaded resources.
- `browser-receipt.json`: measured results, original image digest, evidence boundaries and cleanup.
- `source-hashes-before.json`, `source-hashes-after.json`: 64 explicit source/CSS imports had unchanged bytes across capture. The worktree contained uncommitted changes; file hashes bind the evidence more precisely than its base commit.
- `loaded-source-hashes.json`: requested source modules plus explicit CSS imports and their local CSS import closure (274 files, with the manifest scope stated explicitly).
- `payload.json`, `expected.json`, `synthetic-provider-request.json`: exact synthetic input and byte derivation. The envelope uses the protocol-required producer constant, not a claim that a real Keeper produced this fixture.
- `fixture.ts`, `index.html`, `vite-server.mjs`: standalone fixture and HTTP middleware. The component and CSS are imported from the owned worktree rather than copied or replaced by renderer helpers. Starting the fixture with the existing dashboard dependencies requires `node vite-server.mjs`; no install or production build was performed.

The first fixture used an invalid producer literal, null optional fields and an inconsistent fresh-memory revision. The actual decoder rejected it visibly. `attempt1-*` retains that refusal and its input; only artifact fixture data was corrected. No product source was changed by this browser task.

No real MASC API, Board, Keeper, model, credential, installation or deployment operation was performed. The synthetic dev-token route returns 404; the synthetic turn-record route returns the fixture. Observed HTTP resource origins were only localhost:5195. This is component/browser evidence with a synthetic backend, not evidence of the complete production dashboard or a live peer delegation.

TaskSpace 42 was absent when queried. With explicit permission, a new dedicated TaskSpace 44 (`masc-26049-input-source-evidence`) was created and used only on p1. After capture, both owned fixture-server processes were stopped (initial PID 24089, final PID 55303), port 5195 had no listener, and TaskSpace 44 was finished with no retained pages. No other space was claimed or finished.
