# Namespace Pause/Resume control evidence

Task: task-647. Issue: [#27053](https://github.com/jeong-sik/masc/issues/27053).
The historical record below was assembled on 2026-09-30 after its captured runs.
The current readback fixture was captured on 2026-10-01; its separate receipt,
source hashes and screenshots are identified below.

## Scope and source identity

The Dashboard called unavailable raw MCP pause/resume/status tools. The change
uses the existing namespace operator actions and their server confirmation
tokens, then reads namespace truth before reporting success. Both header and
flow panel use the same confirmation path.

The owner allowed this implementation path in
[issuecomment-5902209171](https://github.com/jeong-sik/masc/issues/27053#issuecomment-5902209171).
Base: `ae82a3b855cc5cb8c37a134ef01eebff35368bc3`.
On 2026-09-30, `git fetch --no-tags origin main:refs/review/647-current-main`
resolved to `d652fb617c4b4b6e420a277827e39359c52ee159`; the diff from base
for the flow-control directory, header control, operator-actions.ts and
namespace-truth-actions.ts was empty.

The historical `browser/receipt.json` pins the original and fixed flow-state
sources by SHA256. The fixed source **at that capture** had digest:
`f3b052505fba3e207fa083c9204193886131bc12bd3624695b69a151362ece85`.
`SHA256SUMS` verifies the current source/test bytes and the retained historical
evidence files separately. Historical browser success does not certify the
subsequently changed flow state.
[근거] Git source/diff commands and captured source bytes, 2026-09-30 UTC;
High for this checkout; deployment identity was not measured.

## Current readback fixture (2026-10-01)

`browser-current-run.json` records the actual Chromium command and exit 0 from
2026-10-01T01:24:30.730142Z through 01:24:35.475973Z. Its complete combined
output is in `browser-current-run.log.gz`; `browser-current/receipt.json` records
all four scenarios and zero page errors. Production source was unchanged during
execution at `89be7af1a92479ef58a86c1cec1c9f12d29d7c25`; the current flow-state
SHA256 is `b68cb5fec23ef834d8303040c26523c184648413eaa043135724ecc89053a756`.

The fixture uses explicit admin standing, as the current controls require.
The original source still calls unavailable `masc_resume` and shows an error.
Current source first requests `namespace_resume`, confirms the returned token,
reads `/api/v1/dashboard/project-snapshot`, then calls `masc_pause_status` through
`/mcp`. The last response decides the result:

- Current readback returns `paused=false`: the control shows Running and a
  `Namespace resumed.` success message.
- Readback returns a JSON-RPC error: the control shows an error and no success
  message, despite the fixture's accepted resume.
- A new authoritative pause occurs before readback: the control remains Paused
  and shows a warning instead of a success message.

The 1280px and 375px images in `browser-current/` show each result. The three
`*-confirm.png` images show the pending confirmation before changing pause state.
The page skin, auth standing, stores and HTTP responses are isolated fixtures;
these screenshots do not prove production styling, server authorization, durable
pause storage, fleet scheduling or provider use. The earlier sandboxed browser
launch failed before page creation with a Mach-port permission error; the
recorded successful run was executed separately in the parent session.

## Historical checks (2026-09-30)

Each JSON receipt contains the exact command, working directory, UTC start/end
and process exit code. Its matching gzip log contains combined stdout/stderr.
All logs are compressed without changing their original bytes; decompress the
named logs below with `gzip -dc <name>.log.gz`.

| Claim | Receipt and output | Observed result |
| --- | --- | --- |
| Added behavior regressions reject original wiring | red.json / red.log | exit 1; 10 failed, 5 passed |
| Focused controls and related operator/confirmation suites | green-final.json / green-final.log | exit 0; 8 files, 62 tests |
| TypeScript type check | typecheck.json / typecheck.log | exit 0 |
| ESLint on four edited Dashboard files | eslint.json / eslint.log | exit 0 |
| Full Dashboard Vitest | full-final.json / full-final.log.gz | exit 0; 728 files, 10,245 tests |
| Chromium A/B fixture | browser-run-2.json / browser-run-2.log, browser/receipt.json | exit 0 |
| Python evidence runner lint and format | python-lint.json / .log, python-format.json / .log | exit 0 |
| Python evidence runner strict type check | python-typecheck-checked.json / .log | exit 0; 1 file; 0 errors/warnings |
| New changelog fragment | changelog-fragment.json / .log | exit 0; 1 fragment OK |
| Whole changelog directory | changelog-full.json / .log | exit 1; 11 malformed inherited entries |

Full Vitest ran from 2026-09-30T15:19:20.947982Z to
2026-09-30T15:26:03.285341Z. The uncompressed full log has 158,813 bytes and SHA256
`be7d98e0b93f622bd4c864754d1e0ce35497ab58047775be6b08959e681dacbf`.
The gzip was checked by decompressing and comparing all bytes.

The initial intermediate GREEN and browser harness attempts failed and are not
counted as passing evidence. Python Ruff/Pyright were initially unavailable;
they were installed in an uncommitted local tools directory. Pyright's Python
launcher hit a read-only cache and a direct internal entry point lacked type
stubs. The package's public Node entry point passed with
`{"typeCheckingMode":"strict","include":["docs/evidence/2026-09-30-namespace-resume/run.py"]}`.
[근거] Named command receipts and complete logs above, 2026-09-30 UTC; High
for these local executions. No PR CI result is asserted.

The whole changelog check fails on 40282, 40293, 40296, 40301, 40304, 40306,
40316, 40319, 40320, 40325 and 40327. These inherited files are unchanged in
this PR; `git diff ae82a3b855cc5cb8c37a134ef01eebff35368bc3 HEAD --name-only
-- changelog.d` lists only 40378.md. The same 11-file defect is tracked in
[#40360](https://github.com/jeong-sik/masc/issues/40360). The 40378.md-only
control uses the existing checker with `--dir` and passes. The global check
must be repaired separately before claiming it passes.

## Historical browser result and limits (2026-09-30)

`browser.mjs` loads actual EmergencyStopControl, FlowControlPanel,
ConfirmDialogOverlay and API serializers in Chromium. Store projections, HTTP
responses and the small page skin are fixtures.

- Original source posts `masc_resume` to `/mcp`, gets -32601, remains paused,
  and shows an error.
- Fixed source posts `namespace_resume` to `/api/v1/operator/action`,
  shows the confirmation dialog, sends its server token to
  `/api/v1/operator/confirm`, then reads
  `/api/v1/dashboard/project-snapshot`. It remains paused until confirmation
  and ends with paused=false and a success message.
- Both variants had zero Chromium page errors. PNGs show the original/fixed
  1280px and 375px fixtures and the pending confirmation dialog.

See `browser/receipt.json`, `browser/main.png`, `browser/fixed-confirm.png`,
`browser/fixed.png`, `browser/main-375.png`, `browser/fixed-375.png`.
[근거] browser-run-2 captured 2026-09-30T15:10:47.173166Z through
15:10:51.333334Z; High for this isolated fixture.

The deployed server, real authorization session, persisted pause record,
fleet scheduling and full production page styles were not exercised.
Browser fixture success does not establish live pause/resume success.
Independent review, merge and live readback remain before task completion.

The host evidence-record template/validator were unavailable in this sandbox.
The required validator invocation exited 127 (missing script); attempts to read
both files from the host repository via GitHub returned 404. Their format check
is therefore unverified; this is separate from the passing code checks above.

## Reproduce

From `dashboard/`, with its locked dependencies installed:

```sh
env -u MASC_CONFIG_DIR -u MASC_BASE_PATH npx vitest run --no-file-parallelism --maxWorkers=1
npx tsc --noEmit --pretty false
node ../docs/evidence/2026-09-30-namespace-resume/browser.mjs . ../docs/evidence/2026-09-30-namespace-resume/browser-rerun
```

The browser requires Playwright Chromium. Use a new output path so original
evidence is retained. Run `sha256sum -c SHA256SUMS` from this evidence directory
to verify the committed bundle. No production namespace is changed by this
harness.
