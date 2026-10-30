# Requested Dashboard file existence guard (#40272)

This is a source candidate. It does not run Vitest, build the Dashboard, or prove that every requested selector executed.

## Observed failure and exact baseline

The retained `c46` artifact log at `/tmp/masc-dashboard-item-domain-reconcile-publish/c46-job.log` records four supplied feature-file selectors, including nonexistent `src/components/keeper-items-workspace.test.ts`. Vitest reported three files and 20 cases while the workflow succeeded. Root independently confirmed that missing path as HTTP404 in actual c46. The log SHA is retained in `source-checks.json`; the root supplied those external run/path facts, and this child performed no network lookup.

The exact actual-main workflow snapshot is `/tmp/masc-dashboard-artifact-main.json`, Git blob `74872837e39e77f8f804cf42d59f299dc67689b2`, supplied at main `0a8ecf4a2dcbf473ef674ac3e7d3fe32381e8672`, tree `fd9d751412febfc5511969ddaca0449a4c8fdc6c`. Its bytes and Git blob/size were verified before import. Local baseline `771668de51eb7946e9cbd224423a1f2e5e72f4ba` contains only that workflow snapshot. It is a partial source import, never a whole-main publication baseline. Root must overlay only this child delta onto the full actual-main GitData tree.

## Assigned publication

Root assigned PR #40272. Initial API head `3d2b751bf2d4174caaf4912d59965d0f38ae7386`, tree `6ad08d3aab5dc61333d3274b38d3dd52466f7f4a`, preserves actual-main parent `0a8ecf4a2dcbf473ef674ac3e7d3fe32381e8672`, tree `fd9d751412febfc5511969ddaca0449a4c8fdc6c`. This follow-up renames the local placeholder fragment to `changelog.d/40272.md` and records the assigned publication here. Workflow and `source-checks.json` bytes are unchanged. Root composes only the assigned fragment and this README onto the initial published tree; local partial ancestry is not the publication baseline. No current-head CI result is claimed by this update.

## Narrow change

In the existing `Verify requested dashboard features` step, iterate the existing parsed array and require each supplied exact file path to satisfy Bash `-f` before invoking Vitest. Missing or non-file paths print an explicit path on stderr and exit1. Quoting preserves the parsed path bytes without glob expansion or command evaluation.

The workflow input, one-line space-separated array parser, Dashboard working directory, Vitest command/configuration, fixed suites, build/package steps, permissions and concurrency remain unchanged. No script, configuration knob, dependency or permanent test suite was added. Symlinks to regular files follow ordinary Bash `-f` semantics. The existing `read` consumes one input line; newline behavior is unchanged and lies outside this delta.

The existing Vitest include contract remains in `dashboard/vitest.config.ts` (`src/**/*.test.ts` and `design-system/**/*.test.ts`). This repair does not mirror that framework or accept patterns: the supplied entries must be existing exact files. Existing files outside that include contract can still be omitted by Vitest. The guard closes the observed missing-file gap and is not an emitted test inventory or per-selector execution-count assertion.

## Source checks

PyYAML BaseLoader read both workflows and confirmed all parsed workflow structure except this run block identical. `bash -n` checked the complete modified run block, including the unchanged Vitest command, with exit0. A temporary fixture used the exact run prefix before that command: an existing file reached the final boundary with exit0; an existing-plus-missing request exited1 with the missing path and no final-boundary output. No Vitest command ran, and the temporary fixture was removed.

`source-checks.json` records those two meaningful shell reproductions and the exact workflow/log hashes. Independent read-only review found no remaining source finding and confirmed the same file-existence limitation. Whitespace was checked before commit. Current-head CI remains root-owned; this candidate has no native, build, test-suite, bundle, browser, release or production proof.
