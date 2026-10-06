# Dashboard Lane declaration draft lifetime evidence

Base: `293520d7e3117128e845fbdb03c8f10af21685f5`. `checks.json` pins the authored source bytes, commands/results, and evidence hashes. The source was uncommitted at verification time; these are author checks, not independent review or approval.

## What changed

A Lane declaration session owns file drafts, active file, new-file identity and async operations independently of Status component mounts. Sessions are scoped by the accepted execution workspace root and current inventory configuration directory. Exact captured authority identity fences requests, including A → B → A. Unknown authority never creates a fallback session. The panel admits the session only after reading inventory under current authority, explains unavailable editing, and offers **Verify workspace** using the existing execution refresh contract.

Status route navigation, editor close, file switching and workspace switching keep drafts in browser-tab memory. There is no localStorage or persistence across page reload/browser exit. The dirty beforeunload guard stays active while another Status page is displayed. Completed file saves remain distinct from pending Lane reconciliation.

In-flight requests are not canceled by unmount or authority changes. Their original document remains busy until the promise settles. A completion under changed authority leaves the original draft with an uncertain outcome and requires a fresh read before another save; it does not overwrite a later workspace. Late creation under unchanged authority migrates the file identity and rotates the new-file identity without relying on a mounted callback. A separately opened destination owns its newer draft/operation; additional create-time edits remain available for comparison.

## Executed checks

- Focused Vitest: **54/54**, four files (`lane-declaration-editor.test.ts`, `lane-addons-panel.test.ts`, `status.test.ts`, `lane-declarations.test.ts`). Includes actual Status/router navigation, read/save/create completion after unmount, late-create destination collision, A → B → A late-read rejection, unknown authority, recovery success/failure and fresh-inventory admission. Existing transport/error and action tests remain included.
- `pnpm exec tsc --noEmit`: exit 0, empty diagnostic log.
- ESLint: session owner, editor and panel plus their two test files; exit 0, empty diagnostic log.
- Chromium: **10 assertions**, actual Status/router/Lane editor with synthetic HTTP and an explicitly accepted fixture execution authority. DOM checks prove editor unmount, dirty guard on Skills, draft restoration without reread, late-create migration, newer pending edits, fresh New identity and workspace isolation even with identical declaration directory. Exactly one explicit POST, no page errors, console errors or unexpected HTTP routes. Both screenshots were visually inspected.

## Reproduce

From the repository root, with Dashboard dependencies present:

```sh
pnpm --dir dashboard test src/components/lane-declaration-editor.test.ts src/components/lane-addons-panel.test.ts src/components/status.test.ts src/api/lane-declarations.test.ts --reporter verbose
```

From `dashboard/`: run `pnpm exec tsc --noEmit` and `pnpm exec eslint src/lib/lane-declaration-sessions.ts src/components/lane-declaration-editor.ts src/components/lane-declaration-editor.test.ts src/components/lane-addons-panel.ts src/components/lane-addons-panel.test.ts`.

For the isolated browser fixture, start Vite from the repository root with `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 pnpm --dir dashboard exec vite --host 127.0.0.1 --port 5198 --strictPort`, then run `node dashboard/evidence/2026-10-04-lane-declaration-drafts/browser-fixture.mjs` in another shell. Stop Vite afterward. The HTTP driver deliberately continues module requests such as `/dashboard/src/api/...` and intercepts only actual `/api/...` requests. An initial driver run waited on an absent textarea aria-label and was stopped; the corrected driver uses the accessible label locator. This was a fixture-selector issue, not a product failure.

No local Dune/native/full CI, real backend/filesystem write, provider, deployment or page-reload persistence was exercised. Synthetic receipts and workspace publications are not evidence of those operations. The temporary dependency symlink and local Vite process are removed/stopped after this run.

## Stack integration and review response

The initial 54-test evidence above was collected against the original author base.
The change was then stacked on `d819bd3221b614a0f7c1731752556ccac715de3a`,
which includes package readings and removal guidance. `integration-checks.json`
records 57/57 focused tests, typecheck and lint at the pre-response source;
`integrated-browser/` records the repeated 10 browser assertions.

Independent source review found that an old comparison could be adopted after a
pending read/save crossed workspace A → B → A, bypassing the fresh-read recovery
requirement. The response clears that comparison and rejects adoption while the
document is busy or needs a read. Two actual component-flow cases failed before
the fix and passed afterward. `response-checks.json` pins the final source bytes:
**59/59 tests**, typecheck and changed-file lint pass. `response-browser/` records
10 repeated routed Chromium assertions and two screenshots inspected by the root
reviewer. The new stale-comparison cases are component evidence; the browser
scenario exercises navigation, late creation and workspace separation.

These are frontend and scoped source-review results. Real backend writes, native
TUI/PTY, deployment, GitHub independent approval and merge remain unverified.

## Current parent integration

Integrated published parent `4ea9a34a60f7e0b81839a477e94ad4573446c4ec` cleanly.
The session owner, editor, editor tests, panel, authority store and declaration
transport retain their audited child bytes. The parent unsafe-integer reading
refusal and regression, plus removal labels and guidance, are preserved.
Sessions still separate workspace root and configuration directory, fence pending
responses by exact accepted authority identity, and require fresh comparison
following a request that crosses authority changes.

Current local verification: 60/60 tests passed in the four suites listed above
(4.58 seconds); TypeScript and scoped ESLint exited 0. No native build, new
browser capture, real backend/filesystem write, CI or deployment was performed.
Earlier screenshots, manifests and logs remain historical with their original
source scope; these new checks do not reclassify them as current browser proof.
