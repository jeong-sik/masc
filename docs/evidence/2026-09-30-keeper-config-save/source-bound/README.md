# Published-source execution binding for #40266

[근거] `verify.py` ran on 2026-09-30 13:25:06–13:25:26 UTC. Confidence: High for the recorded local executions and source bytes; installed-server and CI acceptance were not measured.

The tested commit is `056c5648b13d2c6b2829390554b4f03d093e418a`, with Dashboard tree `5f4ba69bc04f29b0ef69cfa5de921c373fb697e6`. The evidence-only follow-up commit retains this Dashboard tree. `run-132506Z/sources.json.gz` lists all 2,086 tracked Dashboard files with their Git blob and SHA-256, plus the exact runner and browser-script SHA-256. The runner compares working files against `git ls-tree -r HEAD -- dashboard` before execution and repeats the snapshot after execution. The snapshots were identical.

| Recorded command | Result | Raw output |
|---|---|---|
| `pnpm exec vitest run src/components/keeper-config-panel.test.ts src/api/dashboard-keeper-config.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1` from `dashboard/` | 135 tests passed, exit 0 | `run-132506Z/focused-vitest.log.gz` |
| `pnpm exec tsc --noEmit --pretty false` from `dashboard/` | exit 0, no diagnostics | `run-132506Z/typescript.log.gz` |
| `node docs/evidence/2026-09-30-keeper-config-save/browser.mjs dashboard <new-output>/browser` | 4 POSTs, exit 0, no page errors | `run-132506Z/chromium.log.gz` |

`run-132506Z/execution.json` records each command, working directory, UTC interval, exit code, and raw/compressed output SHA-256. Its `source_unchanged` and `passed` values are both true. The browser receipt includes request payloads, DOM snapshots, and the prompt-value trace. Four PNGs capture the actual source panel. Responses are held until later edits are entered; second-save payloads assert the new revisions and preserved values. All API traffic is an isolated synthetic fixture on loopback.

Earlier failures remain visible in `failed-131014Z/`: the 13:10:14–13:10:46 UTC browser attempt timed out waiting for the first prompt edit's `수정됨` marker, after two successful Skill requests. It did not reach prompt POSTs. `browser.mjs` and `verify.py` there reconstruct the exact bytes recorded by that attempt's manifest; their hashes were checked before copying. Another earlier attempt stopped at the same marker (13:02:00–13:02:52 UTC), and the first setup attempt lacked Chromium. These are not counted as passing browser runs.

The added trace also records the first prompt input briefly returning to `Original instructions` for one animation frame before returning to `First instructions`. The passing run then preserves `Later instructions` through the save response. The relationship between the transient first-input value and the earlier dirty-marker timeouts remains unconfirmed. A controlled blur-at-that-frame probe did not complete within its 50-second execution budget. No assertion was removed, no wait limit was increased, and no Dashboard source changed to obtain this result. This package proves the recorded run; it does not establish that the browser sequence is free of timing failures.

The earlier 728-file / 10,212-test full-suite output in the parent folder is historical. It was not rerun here and did not record per-file source hashes. This supplement closes the source-binding gap for the fresh focused tests, type check, and browser execution only.

Reproduce from repository root with the published Dashboard tree and Playwright Chromium available:

```sh
python3 docs/evidence/2026-09-30-keeper-config-save/source-bound/verify.py "$(git rev-parse HEAD)" <new-output-directory>
```

Inherited `MASC_CONFIG_DIR` and `MASC_BASE_PATH` are removed by the runner. This Linux ARM64 sandbox used a locally downloaded Chromium headless shell and locally extracted system libraries; the recorded environment paths are in `execution.json`. Those binaries, caches, and dependencies are not included in the PR. `gzip -dc` reads each compressed JSON/log without changing its original bytes; `sha256sum -c SHA256SUMS` checks the package from this directory.

The runner also passed Ruff check/format and Pyright, and `browser.mjs` passed `node --check`. Raw checker outputs are under `quality/`. The workspace evidence-format validator could not be retrieved through this lane (GitHub contents returned HTTP 404); its format check is not claimed.

— jazz-developer 🎷
