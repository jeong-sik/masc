# Machine activity inventory readout

Machine inventory states require both `activity` (`on`, `off`, `unobserved`)
and `publication` (`no_screen`, `stable`, `running`). The producer reads owner
activity and publication without starting a machine. Both decoders preserve
every combination and reject missing or malformed activity. TUI and Web show
the two readings independently, including Off with a stable screen.

Dedicated machine activity editing is a later unit. This change provides
inventory readout and directs operators to the Runtime source editor.

## Checks executed

From the repository root:

```sh
PATH=/Users/dancer/.opam/5.5.1/bin:$PATH python3 dashboard/evidence/2026-10-05-machine-lane-activity/check-inventory.py
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 node dashboard/evidence/2026-10-05-machine-lane-activity/browser-fixture.mjs
cd dashboard
node node_modules/vitest/vitest.mjs run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/api/lane-inventory.test.ts src/components/lane-inventory-panel.test.ts src/components/browser-lane-activity-panel.test.ts src/components/exact-lane-activity-panel.test.ts
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src/api/lane-inventory.ts src/api/lane-inventory.test.ts src/components/lane-inventory-panel.ts src/components/lane-inventory-panel.test.ts
```

The actual inventory decoder, display module and their direct tests compiled
with OCaml 5.5.1 in isolation: 16 tests passed. Existing production exact/phase
decoder blocks are extracted by source markers; namespace aliases stand in for
the full library layout. The script and provenance record that boundary. This
is not a full MASC/TUI link. Nine changed OCaml files parsed and the shared
Python fixture passed AST parsing (`syntax.json`). The native server inventory
serialization matrix was authored and parsed, not linked or executed.

Web: 82 tests passed in four files, full dashboard TypeScript exited 0, and
the four named source files passed ESLint. Tests use actual decoder/component
code with a mocked inventory fetch. Logs have outer blank lines and trailing
whitespace normalized; empty typecheck/lint output means those commands exited 0.

Chromium used actual Status, inventory, API decoding and styles against
synthetic HTTP. Seven checks passed: Off with stable publication, policy copy
without a toggle, unobserved activity with running publication, rejection of a
missing activity and marked retained reading, explicit refresh recovery, mobile
page width, and no writes/errors/unexpected routes. Three inventory GETs and
zero mutations occurred. Both screenshots were inspected. This is not machine
execution or a real server integration test.

No Dune, full native build, PTY, real Runtime publication, machine execution,
CI, deployment or merge was performed by this readout work unit. Parent-owned
configuration/admission changes require their own evidence.
