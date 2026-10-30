# Equipped portrait: native HTTP PNG replay in the browser

Browser scenario PASS with five screenshots, three image requests, three
distinct object URLs, two correctly revoked URLs, and no uncaught page error.

## Source and native evidence

- Browser checkout: clean `7df3bd2d41c71d3a41597e578d32618cc5662b0c`.
- Native fixture binary: embedded commit
  `2c413a064c82f57c722fed3c7f99c485c1c0429f`.
- CI run: <https://github.com/jeong-sik/masc/actions/runs/36593262327>.
- Artifact: `candle-remote-tui-portrait`.
- `native/native-fixture.log` records the selected real HTTP-router purchase,
  equip, reset and remote-wire scenario: **one test successful in 0.648s**.
  Other HTTP tests in that selection were skipped.
- The broader 27-suite target has separately reported failures. At the single
  metadata read used here, the workflow was still `in_progress`. This evidence
  does not assert whole-workflow or whole-native-suite success.
- The actual `KeeperPortrait`, equipment decoder and auth/fetch module hashes
  match the native commit exactly. Both PNGs are 160×160 and their bytes,
  embedded binary identity and ETags are retained and verified.

## Measured browser behavior

1. The actual production `KeeperPortrait` parses the native roster's Ready
   reading and shows its native beanie PNG.
2. Updating the same Keeper to the native crowned reading requests the same
   portrait URL. The browser sends the previous ETag, accepts the new PNG, and
   revokes the previous object URL.
3. An injected Unavailable observation removes the PNG, displays the fallback,
   revokes the crowned object URL, and performs no image request.
4. Restoring the same crowned reading starts a request. While its response is
   deliberately held, the production component shows loading and no image;
   the revoked prior URL never reappears.
5. Releasing the response shows the exact crowned native bytes in a new object
   URL. All three requests use the fixture auth token and fetch `cache:no-cache`.
   Browser HTTP requests use `Cache-Control:max-age=0` and send cached ETags on
   the second and third request.

The screenshots show a controlled browser component fixture with explicit
labels. The portrait image and Ready observations come from the real native
HTTP scenario. The Unavailable transition and held recovery response are
browser controls. This is not a live server, full dashboard navigation,
purchase interface, or completed remote-TUI PTY proof. No local native build
or production mutation was performed.

## Files and reproduction

- `01-before.png` → `02-equipped.png` → `03-unavailable.png` →
  `04-recovery-loading.png` → `05-recovered.png`.
- `evidence.json`: hashes, native manifest/log, source identities, CI metadata,
  requests, auth/cache assertions, blob lifetime and screenshot hashes.
- `native/`: original PNGs, roster JSONs, native manifest and selected-test log.
- `scenario.mjs`, `run.log`, `SHA256SUMS`: reproducible harness and integrity.

```sh
node scenario.mjs /path/to/masc ./native /path/to/new-output \
  36593262327 2c413a064c82f57c722fed3c7f99c485c1c0429f
```

Vite uses the existing dashboard dependencies and a fresh headless Playwright
Chromium context. The fixture retains all source and payload hashes so a later
run with changed source cannot silently replace this evidence.
