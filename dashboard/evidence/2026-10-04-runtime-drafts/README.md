# Runtime editor draft sessions (B7)

The pre-fix regression loses an unsaved raw draft and selected section after
component unmount/remount. `tests-before.txt` records that failure. Focused
component/API tests cover retention, hidden unload protection, late save/newer
edits, identical paths in different workspaces, A-B-A during a write, external
write notification, changed paths, lost authority and exact projection refresh.
API tests hold authentication and verify zero dispatch after authority changes.
Two review findings added explicit projection checks: old responses after reload,
and first registry publication after a delayed setup resume and editor remount.
A further review found that raw edits during a typed patch could undo that patch
on the next save. `typed-patch-before.txt` records the failed regression; only
raw saves now permit concurrent raw edits. Typed patches block both the textarea
and queued draft updates until they settle.

Run from `dashboard`:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 node evidence/2026-10-04-runtime-drafts/browser-fixture.mjs
```

The harness owns an ephemeral Vite server and Chromium. It renders actual
Status/RuntimePanel/router/editor components and API decoders against synthetic
HTTP. It makes two explicit raw saves, including a held receipt while navigating
away, and checks later edits and workspace-separated drafts. The standalone lane
wire fixture is reused from the previous CAS fixture. An initial harness attempt
omitted the required nonempty protocol inventory; that failure is saved separately.
It is not a product or backend failure.

This is not native backend/TUI, model invocation, worker, deployment or merge
evidence. Session persistence is in tab memory; page reload and unfinished new
provider/model forms are outside this patch. Shared runtime caches outside the
editor have a separate pre-existing workspace isolation gap.

`checks.json` records final results and source hashes. The touched API module has
two existing `no-nested-ternary` lint errors at lines 987/989. Parent and current
API lint output are retained; the new session, editor and focused tests pass lint.
