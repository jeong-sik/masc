# Retained output after a failed request

Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).
Parent source: `2c20d1e1fc9bf21052ae6fa3c31066f607477a61`.
Changed source fingerprints: [source-sha256.json](source-sha256.json).

A history row can contain completed media followed by a failed request terminal.
The dashboard previously discarded those persisted blocks. The new regression
fails on the parent implementation because the image and audio disappear
([before.log](before.log)). Failure presentation is now owned by
`failure-message.ts`, with the copy effect supplied by the chat owner.
Persisted output renders alongside the failure. Neither the backend writer nor
the REST normalizer synthesizes speech blocks from server diagnostic text.

## Executed checks

- `pnpm --dir dashboard test src/components/chat/primitives.test.ts src/keeper-state.test.ts`:
  250 passed ([dashboard-tests.log](dashboard-tests.log)).
- `pnpm --dir dashboard typecheck`: passed ([dashboard-types.log](dashboard-types.log)).
- The new media regression was rerun after correcting its canonical provenance
  fixture: 1 passed ([media-test.log](media-test.log)).
- `opam exec -- dune exec -j 4 test/test_keeper_chat_store.exe -- test row_kind`:
  completed output survives persisted failure reload and callback re-entry;
  its matching input remains pending ([core-tests.log](core-tests.log)).
- Local browser: image decoded, audio played, failure status retained, diagnostic
  expanded/collapsed and copied, no page errors ([browser.json](browser.json)).

The browser runs the production `ChatTranscript` and REST normalizer against a
local fixture, without a live MASC backend. The viewport is the real bounded
transcript: [overview.png](overview.png) captures the failure heading after
scrolling up; [collapsed.png](collapsed.png) captures retained media and controls;
[expanded.png](expanded.png) captures opened diagnostic details.
This is local rendering evidence, not a deployed dashboard or provider failure
experiment. No full build, CI, installation or deployment is claimed.

## Reproduce the browser interaction

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 pnpm --dir dashboard exec vite --host 127.0.0.1 --port 5197 --strictPort
# In another terminal, from dashboard/:
node e2e/failure-output.mjs
```

The fixture uses its own local SVG and one-second WAV. The proxy target is an
unused loopback endpoint; no live runtime state is required or changed.

## Remaining work

The TUI reader's equivalent output omission still needs repair. This unit also
does not remove `kind`; the next contract change must remove the fake assistant
failure producer and update all acknowledgement, journal and UI readers together.
