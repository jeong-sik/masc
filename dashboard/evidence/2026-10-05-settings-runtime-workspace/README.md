# Settings Runtime workspace ownership (B10)

Settings previously retained the first workspace's defaults/resolved/providers
while another workspace became current. Typed routing/media/lane actions did not
recheck workspace ownership after token acquisition. The original B10 evidence
here pins c2e74cc3318a666d461164d23fcbec9089854069, with three actual-component
reproductions. The transport for the routing reproduction intentionally rejects
before any server write. The branch parent is the separate Web Browser activity
PR at 5f8c3c6b5cd0cdfa4d1896b073d9e377f009c0ad, which has the same causal defect.

The repaired Settings surface creates fresh readings for each accepted authority
object and withdraws old values before effect cleanup. Reads reject late owners
and superseded file generations. Typed writes all recheck authority after token
acquisition; lane candidate edits retain the fresh-file revision CAS and declared
order checks. An unanswered dispatched write requires a subsequent complete
refresh including the file; an older refresh cannot clear that uncertainty.

Unmount cancels reads and unsent intent. An already-sent write still processes
its receipt, invalidates raw editor save bases and resumes model setup while its
original workspace remains current. Workspace changes abort the resume/follow-up.
Resume completion publishes an observation revision for remounted Settings,
Runtime editors and All Lanes, without pretending a second file write occurred.
The independent raw Runtime draft remains intact. These are client ownership
checks; they do not roll back a write already accepted by the server.

## Executed checks

From `dashboard/`:

```sh
node node_modules/vitest/vitest.mjs run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/components/settings-surface.test.ts src/api/dashboard-runtime-routing-lifetime.test.ts
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src/lib/settings-runtime-session.ts src/components/settings-surface.ts src/components/settings-surface.test.ts src/api/dashboard-runtime-routing-lifetime.test.ts
```

From the repository root:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 node dashboard/evidence/2026-10-05-settings-runtime-workspace/browser-fixture.mjs
```

The API regression ran before the two missing guards were added: 6 failed and
6 passed. The same API tests then passed 12/12, using actual API/core/decoder to
mocked fetch, with only token acquisition held. Final focused execution passed
79 tests: 67 Settings cases plus 12 API cases. TypeScript passed; the named
Settings/session/test lint passed. The API edit itself has a clean diff and is
covered by the full TypeScript check, not claimed as a full legacy API lint pass.

The Settings tests include authority loss, A-B-A late responses, token-wait
changes, old receipt versus a new write, uncertain write versus old refresh,
unmount before/after dispatch, resume cancellation, preserved raw draft, and
post-resume re-entry to both actual Settings and RuntimeTomlEditor.

Chromium uses actual Settings, workspace store, router and API decoding against
synthetic HTTP. Seven checks passed, with 38 reads, two explicit routing writes,
one resume belonging to the still-current workspace, zero page errors and zero
unexpected API routes. The held old read can be transport-aborted; unit tests
also deliver late responses despite cancellation. Desktop and mobile captures
have animations disabled. No page-wide horizontal overflow was measured; the
existing narrow-screen media-failover row still crowds/clips its label/control
content and remains a separate UX follow-up. This is not a broad mobile usability
PASS.

## Review-driven fixes and harness limits

Independent WIP review found three P2 boundaries: an old refresh clearing a newer
uncertain write, same-workspace unmount dropping a sent save's settlement, and
missing post-resume publication to remounted consumers. These were repaired with
an uncertainty identity, separate read/write lifetimes and observation publication;
focused actual-component cases cover each. The reviewer findings were source
causal, not claimed as executed failures on those intermediate WIP snapshots.

Early harness corrections included a duplicate test helper, missing standalone
fixture wiring, and running Vitest once from the wrong root (no tests executed).
Browser authority withdrawal initially used an invalidation helper while a
reconnect was pending; the fixture now uses the actual reconnect reset and serves
unverified execution. The second capture exposed an exact text selector sharing
a node with its button; the product status now has its own paragraph. Initial
browser records are retained. Logs have trailing/outer blank whitespace normalized.

There was no Dune, native TUI/PTY, real Runtime backend save/publication, model
execution, CI, main integration or deployment. The original component audit,
API transport test and browser fixture are separate evidence scopes. B10 is a
source repair until integrated and validated at the operating boundary.
