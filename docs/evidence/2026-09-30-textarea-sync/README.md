# ExpandableTextarea first-input preservation

## Result and scope

On main revision `727fc531230d48f601bc78c7b33f6ad26c5de654`, input immediately after mount or a parent value reset can be replaced by the pending prop synchronization effect. Replacing that synchronization with `useLayoutEffect` applies the parent reset before input is accepted. Blur and fullscreen confirmation still commit the local draft.

This establishes a defect in the shared component. It does **not** establish that the earlier #40334 KeeperConfigPanel dirty-marker timeout has the same cause, nor that a deployed Dashboard has been repaired. #40266's preservation of edits made while saving is a separate change.

## Reproduction and counterexample

`red-final/execution.json` records the actual pre-fix focused command, 2026-09-30 13:54:18 UTC, exit 1. Its log has two failing input-preservation assertions and two passing controls: explicit parent resets replace an existing local draft, and fullscreen confirmation submits the draft. The final test differs from the red version only in two block-bodied `act` callbacks needed for TypeScript's void-return contract.

The production change is confined to the effect import, synchronization hook, and explanatory comment. It adds no state, guard, retry, or timeout.

## Execution evidence

| Run | Result | Source association |
| --- | --- | --- |
| `red-final/` | 2 failed / 2 passed; exit 1 | Pre-fix component at the main revision above |
| `green/` | 119 focused tests passed; ESLint exit 0 | Fixed component; first typecheck failed on two test callback return types, retained in the log |
| `typecheck-final/` | TypeScript exit 0 | Block-bodied test callbacks |
| `full-recovered/` | 729 files / 10,244 tests passed; exit 0; 404.74 seconds | 2,087 Dashboard files measured before and after; identical bytes |
| `browser/` | Chromium comparison exit 0; no page errors | Main component snapshot and actual fixed component, SHA256 recorded in receipt |
| `quality/` | See each command's execution receipt | Final evidence runner and changed TypeScript files |

The full command began at **2026-09-30T14:05:42.731471+00:00** and finished at **14:12:28.453185+00:00**. `sources.json.gz` lists each file's path, size, SHA256 and Git blob identity. `vitest.log.gz` contains the complete stdout and stderr; its decompressed SHA256 is `3714d3ea13d901b82a62effc9b6cd58df66ad2b2d51b18d0768ed6e2585d3e6b`.

An earlier full execution was interrupted between turns and left only a source manifest, with no result receipt or running process. It is not counted as a pass. The recovered execution uses a distinct directory. Evidence files have not been overwritten to replace failed results.

## Browser observation

`browser.mjs` mounts the **actual shared component** in an isolated Vite page. It dispatches input in the same JavaScript task as mount, before passive effects; it does not override Preact's effect scheduler. Only render/effect traces and the textarea DOM value setter are instrumented. There is no deployed server or API fixture in this comparison.

At 14:14:53–14:14:55 UTC:

- Main: input `First instructions` is followed by the pending effect for `Original instructions`, a DOM overwrite, and blur committing `Original instructions`.
- Fixed: synchronization precedes input; the textarea and blur callback both retain `First instructions`.
- Both: a subsequent parent reset displays `Server reset`.

`main.png` and `fixed.png` were captured before the reset. Neutral image analysis read `First instructions` in the fixed textarea; some ancillary button text was unreadable. DOM values and event traces are the precise assertion evidence.

The source hashes are:

- Main: Git blob `d0ceaa59f0236ccdf3ced41de431adbc904dd713`; SHA256 `1840f350ff435ea892c57be34c5acac04cf8e3afb61ea602ec05589f1c0cd5dc`.
- Fixed: Git blob `0c92698b4d2b4e04eca5f22842b0be2373c73cc8`; SHA256 `8e0ba72f05d5f314274641cb062743affb42f69a509a842ab091569154c0971e`.

The browser receipt confirms that the fixed source was unchanged during execution. Main's current GitHub component blob was also directly checked during this verification turn on 2026-09-30 and still matched the pre-fix blob. This is not a claim that the entire main tree stayed unchanged.

All committed command logs use `.log.gz` to retain their exact raw bytes, including terminal control codes and trailing blank lines. Decompress them for reading; no whitespace cleanup was applied to recorded output.

## Re-run

From the repository worktree:

```sh
python3 docs/evidence/2026-09-30-textarea-sync/verify-full.py <new-output-directory>
pnpm --dir dashboard exec tsc --noEmit --pretty false
node docs/evidence/2026-09-30-textarea-sync/browser.mjs dashboard <new-browser-output-directory>
```

The browser command requires installed Playwright Chromium and its system libraries. Its baseline snapshot is the exact source at the main revision above. Every output directory must be new.

The full runner was subsequently formatted, annotated, and given explicit `check=False`; these evidence-script edits did not alter Dashboard inputs or any recorded execution result. Ruff and strict Pyright verify the final script.

[근거] Actual command receipts, source byte manifests and Chromium DOM traces, **2026-09-30 UTC**. **High** for this controlled reproduction and local verification; deployed behavior and the earlier whole-panel timeout remain unverified.

— jazz-developer 🎷
