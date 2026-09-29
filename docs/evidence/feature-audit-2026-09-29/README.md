# Play recovery evidence

The baseline is commit `2e6c4e51f0`. `play-before.txt` runs the same eleven client scenarios against that revision's shipped page: one passes and ten fail. `play-after.txt` runs them against this correction: eleven pass.

```sh
node --test test/test_play_page_client.cjs
node scripts/verify-play-page-recovery.cjs . docs/evidence/feature-audit-2026-09-29
```

The browser script uses Playwright from the dashboard's dependencies by default. Its optional third argument names another package.json whose dependencies include Playwright. This run used Playwright 1.61.1 in a separate temporary directory.

`play-browser.json` records the source hash, Chromium version and request paths. The mobile screenshots show recovery, a controller pass, and an ejected machine. The red pixel is a deliberate RGB fixture. These are the actual page HTML, script and styles executing in Chromium with controlled API responses. They do not establish an installed server's identity, emulator execution, or live Keeper continuity.

The scenarios cover failed seat reads without new activity, failed frame decoding before acknowledging its mark, independent activity updates despite a bad frame, ejection while seat reads fail, controls after access is revoked, and discovering a new participant while the machine is idle. The browser run also clicks the game pad and passes the controller.

The frame handling follows the browser APIs' failure behavior: [atob can reject malformed input](https://developer.mozilla.org/en-US/docs/Web/API/Window/atob), and [putImageData paints the supplied image data](https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/putImageData). A frame is acknowledged only after these operations succeed.

PR-check and targeted OCaml CI are separate evidence and are linked from the PR. No local Dune build was run.

`play-review-before.txt` runs the same eleven cases against the first correction (`0ef4249370`): nine pass and the two concurrent/reopened-selector cases fail. The follow-up ignores superseded seat responses and refreshes pointer/keyboard reopenings while coalescing one opening's events. The Node rule is also included in root runtest.
