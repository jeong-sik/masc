# Exact-artifact native launcher integration review

**OBSERVED PASS** in the bounded native first-party source→statistics, On/Off/reconnect, original-result preservation and actual API/PTY scope. No P0–P2 blocker observed on this exercised path.

## Exact identity and actual launcher selection

- Native run 39937556339; source `a6fba325404c963061b7b95c4c564e35f5ea5e2e`; workflow `d78ce9eb8bec2c351ad84fc2a3b6e92701e56755`.
- Independently read artifact receipt and download-verified, hashed the server/TUI/launcher against receipt, and executed server `build-commit` + TUI `--build-commit`: both source a6fba. See `evidence/artifact-verification.json`.
- Launcher actual SHA256: `fe2803bcddbed5865a5d6213b8340da3c188d67e1a0063391255711ac046e93d`. Its source is bound by this run's receipt and `bin/masc_native_addon_launcher.exe` build target. It has no embedded build-commit interface.
- Actual kernel `proc_pidpath` on this isolated server's child PIDs recorded `/private/tmp/masc-addon-goal-resume-20261021/native-39937556339/masc-native-addon-launcher` for PID 76284, then Python under that same PID. Reconnect PID 84600 independently recorded the same launcher→Python transition. See `actual-launcher-selection.json` and full `actual-owned-exec-paths.jsonl`. No wrapper or replacement was used.
- PATH was `/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`; installed launcher directories were excluded. The production locator source, ordered candidates and hashes are retained. The artifact's adjacent launcher is the first executable candidate.

**The prior source-unknown installed-launcher-copy limitation is resolved for this run.** Only the artifact's actual server/TUI/adjacent launcher ran. The launcher hash remained equal to receipt after execution.

Fresh workspace `/tmp/masc-exact-launcher-review-20261023/workspace`, private HOME/XDG/config, port 63452; server full health confirms matching effective roots and source. Live `/Users/dancer/me/.masc`, installed binaries and other processes were untouched.

## Actual integrated behavior

Unmodified first-party Python `vst-phrase/server.py` reads an explicit valid local snapshot_file; unchanged `output-statistics/server.py` consumes its named `phrase` port through a real `lane_output` binding. Only package manifests change to explicit host_process and omit container-only fields. Local snapshot v1 contains 1 supported known-failure phrase observation; v2 contains 2. This is declared input data, not audio rendering/playback. Neither a mock worker nor completed host result records were injected.

| Stage | Actual observation |
|---|---|
| Source/statistics On | Actual source `01a1684c-8c30-7000-9443-b69f977e36d8` produces 1 row; statistics `01a1684d-3b95-7000-bd0e-95b4c4c6d51b` returns count 1/value1, complete input, producer seq 1 and exact upstream row/evidence |
| Original selection | Actual PTY `05-original-result-selected` selects and reads count 1 |
| Save Off | Real expected-revision API file receipt durable; original instance becomes detached/native_released while selected result stays count 1 |
| Input/observe/reconnect | Real source observes v2, completes seq 2/two rows; new statistics incarnation `01a1684e-3662-7000-a3bc-86863a09eb2f` returns count 2/source seq 2 using the adjacent artifact launcher |
| Preserve original selection | `11-original-result-after-reconnect` retains detached original count 1/source seq 1; raw record12 preserves original row identity |
| Current/history navigation | `14-new-current-result`: count 2. `15-original-history-reopened`: original count 1. `16-current-selection-restored`: separate current selection returns count 2 |
| Original API reread | `12-original-row-reread` and `19-original-row-after-final-off` retain original row fields/provenance/evidence exactly |
| Final cleanup | Both declarations inactive, all 3 native claims consumed, release receipts retained, own processes gone, port reusable |

Original row canonical SHA256 before and both rereads: `9f4182463273e1d2ed5a1b9e2d728b2ccb9921589e947306823a07abe0d7699c`. Original native release receipt equals its final reread. Actual durable file create/save receipts are captured separately. No package-action receipt is claimed; first-party phrase output explicitly has `action_receipt=false`.

## Evidence, cleanup and limits

Evidence: `/tmp/masc-exact-launcher-review-20261023/evidence`. Redacted actual HTTP requests/responses, local input/declarations, raw PTY bytes/commands/cells, 7 PNGs, 20 durable runtime records, actual kernel exec observations and final hash manifest are retained. PNGs rasterize actual PTY cells offline with supplied default colors; they are not OS window or physical paint/latency evidence. A representative current-result image was visually inspected. No screen wording/layout/order assertion or new test exists.

Kernel observation initially treated the libproc return count incorrectly; corrected before both captured launcher→Python transitions. The first source launch itself was not captured, so no per-launch trace is claimed for it. This was observation tooling, not a product failure.

No actual audio/synth, real model/provider/Agent, browser, exported tools, Dashboard, server-restart recovery, whole 54 or general release proof. No local Dune/build/typecheck/executable test or CI polling. No source edits/public writes/approvals. Only exact owned server/TUI/workers were stopped; all are absent and port reuse is confirmed in `cleanup.json`. Prior reports and live workspace remain unchanged.
