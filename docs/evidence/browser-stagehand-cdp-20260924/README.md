# Stagehand v4 extension over raw CDP

Transport spike for [RFC-browser-lane-stagehand](../../rfc/RFC-browser-lane-stagehand.md).
It drives the Stagehand v4 extension with no Stagehand SDK: one CDP websocket, the
extension service worker, and JSON-RPC through `Runtime.addBinding` /
`Runtime.evaluate`. This is the path an OCaml client would take.

## Environment

- Browser: Google Chrome Canary `Chrome/156.0.8071.0`, `--headless=new`, fresh profile.
- Extension: `dist/extension` from `@browserbasehq/stagehand@4.1.0` (npm `latest` on
  2026-09-24). Runtime marker: `protocolVersion 2.0.0`, runtime `1.0.2`.
- Client: `spike.mjs`, Node's built-in `WebSocket`. No npm dependency is imported.
- Page: a local HTTP fixture (heading, price, email field, a button that sets
  `document.body.dataset.clicked = "yes"`).

## Allowed origins

`stagehand.init` takes `browser_cdp_url`, and the extension's service worker opens
its own websocket to that URL. Chrome checks that socket's
`chrome-extension://<id>` Origin against `--remote-allow-origins`.

| `ORIGINS` | Flag | Result |
|---|---|---|
| `none` | no `--remote-allow-origins` | `stagehand.init` fails: `CDP websocket failed to open` (`run-without-allowed-origin.txt`) |
| `extension` | `--remote-allow-origins=chrome-extension://<id>` | whole flow passes (`run.txt`) |
| `any` | `--remote-allow-origins=*` (Stagehand's own launcher default) | passes; used by the first runs, not recorded here |

The id is computed before launch from the extension directory's real path
(SHA-256, first 32 hex digits, `0-f` mapped to `a-p`). Both runs log that it
matches the id `Extensions.loadUnpacked` returned.

## What was measured (`run.txt`, `ORIGINS=extension`)

| Step | Result |
|---|---|
| Launch to runtime marker | 0.6 s here; 0.6–7.1 s over seven runs that day, the first cold run slowest |
| `Extensions.loadUnpacked` over `--remote-debugging-port` | accepted |
| `stagehand.init` with `model: {source: "client"}` | needs `browser_cdp_url`; then returns the initial page |
| `page.goto` | 48 ms |
| `page.screenshot` | `fixture.png` 1280x713 |
| `stagehand.extract` | two `llm.generate` requests reach the host (the extract schema and a progress schema) |
| `stagehand.act` | one `llm.generate` request (4834 bytes, accessibility tree with `[frame-node]` ids); answering `0-18` clicks the button, read back as `clicked = "yes"`; 569 ms, mostly DOM settle |
| Cache | `metadata.cache.status = DISABLED` (local runs have no cache) |

`extension-to-host-requests.json` holds every request the extension sent to the host,
including the full `llm.generate` params (messages, system prompt, `response_format`
JSON schema).

## What this does not show

- The model answers are a fixed stub in `spike.mjs`. It returns the fixture's
  heading and price, and for `act` it picks the id on the `button: Submit order`
  line. Element choice by a real model was not measured.
- Usage is reported as zero because the stub sends no `usage`. A real host must
  fill it.
- No masc code ran. No Keeper, provider, TUI or Slack is covered.
- Only `json_schema` generations were seen. Whether Stagehand sends text or tool
  generations in other paths is open.

## Reproduce

Extract `npm pack @browserbasehq/stagehand@4.1.0` next to `spike.mjs` (it reads
`package/dist/extension`), then run
`ORIGINS=extension CHROME_BIN=<absolute Chrome path> node spike.mjs`
(`ORIGINS` is `none`, `extension` or `any`). It writes to `out/` and a throwaway
`profile/` beside the script and stops Chrome on exit.
