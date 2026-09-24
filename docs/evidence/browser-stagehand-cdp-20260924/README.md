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

## What was measured (`run.txt`)

| Step | Result |
|---|---|
| Launch to runtime ready | ~2.0 s |
| `Extensions.loadUnpacked` over `--remote-debugging-port` | accepted |
| `stagehand.init` with `model: {source: "client"}` | needs `browser_cdp_url`; then returns the initial page |
| `page.goto` / `page.screenshot` | 135 ms / ~80 ms, `fixture.png` 1280x713 |
| `stagehand.extract` | two `llm.generate` requests reach the host (the extract schema and a progress schema) |
| `stagehand.act` | one `llm.generate` request (4834 bytes, accessibility tree with `[frame-node]` ids); answering `0-18` clicks the button, read back as `clicked = "yes"` |
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
`CHROME_BIN=<absolute Chrome path> node spike.mjs`. It writes to `out/` and a
throwaway `profile/` beside the script and stops Chrome on exit.
