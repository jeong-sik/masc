# Board comments and reactions in a Keeper turn

These are actual Chromium renders of the production `KeeperTurnFlow`, API decoders,
Board route helper and Dashboard styles, with **synthetic HTTP responses**. The
capture source is `cbd4d82af44b6a90f187c59e2a759a72b8ab0e4c` (base
`e3e163a1c037202fb20d5b9fadfe228da3cf747a`). `capture-manifest.json` preserves
capture-time paths, source hashes and scope. `current-locations.json` locates the
unchanged retained bytes; it does not assert that later source has those hashes.

| Case | Observed behavior |
| --- | --- |
| `observed.png` / `observed.json` | No recent-tail seed; one exact batch loads three Board actions. A committed reply remains visible beside failed tool delivery; reaction removal and addition have their actual targets. Six original links appear. |
| `denied.png` / `denied.json` | An available recent-tail candidate does not establish whole-ledger uniqueness. A 403 from exact lookup shows three unconfirmed executions and no Board links. |
| `duplicate.png` / `duplicate.json` | The selected reply has duplicate canonical rows despite one recent-tail candidate. That action stays unconfirmed; the other two actions retain three links. |
| `navigation.json` | Clicking the actual parent-comment link produces `#workspace?section=board&post=p-fixture&comment=c-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`. |

Each case made one exact tool-call request, one runtime-trace request and one
physical-Skill request. The fetch fixture rejects unexpected paths. Request
receipts contain only methods, paths and synthetic status codes. There were no
captured page errors. Two Board inputs are shown independently of the actions;
the UI does not choose a stimulus as the cause or infer deliberate no-action.

The browser used ego-browser TaskSpace 42, page p1, with a 1548 × 990 CSS viewport.
The local fixture ran Vite on `127.0.0.1:5193`, with the same Preact and Tailwind
transforms and production stylesheet ordering. Its explicit `@source` supplies
the Dashboard source directory because the fixture lives in ignored artifacts.
The initial capture before this source-scanning correction remains in local
artifacts and is excluded from this bundle. All three retained screenshots were
opened and visually inspected after the correction.

The retained `fixture.ts`, HTML, stylesheet imports and Vite configuration are
capture-time helpers. Their local paths describe this run; select an output
folder under `artifacts/` when adapting them for another checkout. They perform
no live Board writes, model calls or runtime configuration changes. Message and
context buttons are inert fixture callbacks. Board navigation checks the real
route hash; this fixture does not mount the destination Board reader.

Applied frontend checks at the capture source: **144 tests in five files**, full
Dashboard `tsc --noEmit`, and targeted ESLint passed. `frontend-tests.txt` records
the test collection. The backend receipt records **20 OCaml files parsed with
5.5.1**, and `backend-postrebase-source.json` confirms their bytes survived the
rebase. The repository targets 5.5.2. The OCaml regression cases were authored
but **not executed**. No OCaml type check, local Dune build, CI, installed-runtime
or deployment verification is claimed. The inline-composition child association
is a separate producer repair and is not exercised by these synthetic renders.

The later inline child repair has its own `inline-association-source.json` and
`inline-association-parse-only.json`: 12 changed OCaml files parsed with 5.5.1.
The authored real bundle → Board → committed row → TurnRecord regression covers
foreign identities, missing log commits and sealing. It was not executed and is
not part of the browser evidence above. Async observation paths are unchanged.

Later source responses retain the public `Masc_board_handlers` imports in both
Board evidence codec files, expose MCP recording confirmation separately from
Board effect success, and exclude explicit composition child rows from the
top-level raw-transcript invocation slots. Their source and parse receipts are
retained separately. `combined-parse-only.json` records all 38 changed OCaml
files at that combined source; it remains parsing-only with 5.5.1. The five
actual-MCP regression registrations (including post-append uncertainty) and the
transcript slot regression were authored, not executed. The earlier browser
source files remain byte-identical; these responses do not enlarge its proof.
