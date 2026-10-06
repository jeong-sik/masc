# Browser TOML reader repair (B11)

The activity editor previously passed the entire Runtime document to
`getStaticTOMLValue`. Its inherited-key table lookup could mutate
`Object.prototype` for a key such as `[__proto__.browser.automation]`; subsequent
empty documents could then report inherited activity instead of default On.
Even unrelated provider keys reached that conversion when opening the panel.

The reader now walks decoded Browser AST paths, retaining activity and flat
Automation paths in Maps. Unknown Browser keys and table/value shapes are
rejected consistently with `Browser_configuration`. Full absolute-path and
required-path-pair validation remains in the server preview. It does not ban
prototype-like names in unrelated namespaces or rewrite those namespaces.

## Executed evidence

- Same 39 prototype/structure cases: **15 failures / 24 passes before** the
  repair. Afterward all passed as part of **132 tests in 4 files**, including
  the actual Browser panel/session, common inventory and Machine panel.
- TypeScript and scoped ESLint completed with exit 0.
- Chromium ran **9 checks** against actual styled Status, Browser editor/session,
  raw editor, router and API code with **synthetic HTTP**. It observed 5 inventory
  reads, 3 explicit previews and saves (one conflict, two synthetic commits),
  no model-resume call, no page error and no unexpected API route.
- The full special-key document is supplied to the actual Web editor. The
  harness's independent TOML oracle only converts its known benign suffix,
  so the vulnerable library does not contaminate the Node harness. A descriptor
  snapshot taken before page scripts verifies that the browser's actual
  `Object.prototype` is unchanged after read/edit/save. The special source
  prefix must remain byte-for-byte in the saved document.
- Desktop/mobile screenshots are from that run. These inputs intentionally
  exercise the frontend parsing boundary; synthetic preview success is not
  proof that the real server would accept every adversarial namespace.

`before-source.txt` is the exact helper from parent
`a48463a674d43ac4658488eb44f234baa9399756`. `before.txt` was captured before the
product edit, using the same test file. Prototype cases import the actual
helper in fresh child processes so failures do not contaminate other tests.
`source-hashes.json` pins source and evidence bytes. Text logs only strip
trailing whitespace and surplus final blank lines; original log hashes are
retained separately in that manifest.

The first harness run introduced the concurrent file change before a retained
panel's entry read settled. The UI correctly disabled Save, so no write request
occurred; the test timed out expecting the later server conflict. That record is
`browser-initial-entry-race.*`. The final scenario settles an explicit current
read before introducing the concurrent edit. An earlier invocation from repo
root could not resolve `tsx`; run the commands below from `dashboard/`.

## Reproduce

From `dashboard/`, with the lockfile dependencies installed:

```sh
pnpm exec vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 \
  src/lib/browser-lane-activity.test.ts \
  src/components/browser-lane-activity-panel.test.ts \
  src/components/lane-inventory-panel.test.ts \
  src/components/machine-lane-activity-panel.test.ts
pnpm exec tsc --noEmit
pnpm exec eslint src/lib/browser-lane-activity.ts src/lib/browser-lane-activity.test.ts
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 \
  node --import tsx evidence/2026-10-05-browser-toml-reader/browser-fixture.mjs
```

The fixture reuses the prior Browser UI entrypoint in the same checkout,
uses an ephemeral port, intercepts every API route, and removes its temporary
Vite cache. Existing inline comments on enabled values and unrelated source
survive. Comments attached to flat path assignments moved into Automation
remain a known P3 outside this repair.

No actual backend validation/publication, Browser executor, native TUI/PTY,
CI, changed downstack composition, main integration or deployment was executed.
