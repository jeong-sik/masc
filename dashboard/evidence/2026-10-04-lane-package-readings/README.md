# Package-authored Lane readings on the Dashboard

Issue #41100, audit B5. Initial implementation base: `293520d7e3117128e845fbdb03c8f10af21685f5` (#41114). This display repair is independent of the concurrent Lane declaration session repair.

The actual package JSON already includes `binding_schema` and `presentation`; the Dashboard previously decoded only `outputs`. The decoder now retains both contracts. The real panel renders description plus reading label/order/unit/format, resolving each package-local Lane ID within its declaring instance. Missing and wrong-type values display Unavailable. Zero/false remain actual values, multiline text is escaped, and original fields/evidence remain accessible. This does not add installer forms or grant action authority.

## Measured

- 26/26 focused Vitest component/API tests passed, including metadata retention, owning-instance selection, zero/false, escaped multiline text, nested JSON, missing/type/path failure and malformed display format refusal. `focused-vitest.log`.
- TypeScript and changed-file ESLint each exited 0. `check-commands.json`, `typecheck.log`, `lint.log`. The first TypeScript run caught unchecked fixture array access; `typecheck-initial.log` records the failure and correction.
- Actual Chromium 149 fixture: 10 assertions passed against the real LaneAddonsPanel/decoder with intercepted synthetic HTTP. No page/console errors, unexpected routes or writes. `browser-result.json`, `browser.log`.
- Desktop and 390px mobile screenshots were inspected: `readings.png`, `readings-mobile.png`. The fixture and driver are included. The driver URL can be overridden with `LANE_READINGS_FIXTURE_URL`.

`manifest.json` identifies the measured source bytes. No actual backend/native TUI, Docker worker, production endpoint, CI, merge or deployment was exercised. Independent source review and final-stack readback remain separate evidence.
