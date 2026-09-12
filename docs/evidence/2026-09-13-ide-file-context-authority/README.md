# IDE file context authority (2026-09-13)

The installed IDE showed three actionable Code anchors on `lsp-acceptance-sample.ml` even though the file had no related activity. `ide-context-lens.ts` had accepted fileless workspace events, then used the currently selected filename as their file path. The source change removes that invented link. Global history and operational Goal, Task, Board, Telemetry and Keeper routes remain available.

## Installed baseline

`installed-baseline-receipt.json` and `installed-baseline.png` come from the real installed MASC dashboard at commit `4324764e959a5ff8b265b292e5bab9f68e550313`, executable SHA256 `a38ff7f2e6ecbd9efe6dcfbb2469d67e56e837f3cad7eba0fa2f7eed6571643a`. The browser selected the registered probe-owned repository and its actual source file, expanded Observation context and Work Context, and read real HTTP responses. The selected file had 0 file events while the Context Lens displayed 3 anchors with Code actions. The workspace API returned 50 of 1972 persisted activity events; the codebase-specific IDE events API returned 0. The relevant lens, Activity, Reaction Thread, Keeper Work and Persistence source files have identical contents between that installation and integration candidate `d1d04bef3d391a7398b83c210f6c0fd04f57cbb3`.

This was read-only discovery. No original project, Goal, Task or Keeper was changed, and no fixture source was changed. Unrelated dashboard WebSockets and mutation requests were blocked by the probe; its general reconnecting indicator is not evidence of a production connectivity defect. The complete temporary observation is `/tmp/masc-workspace-context-inspection-20260913`.

## Source behavior and authority

The existing `/api/v1/ide/events?codebase=...` handler resolves a canonical codebase and reads that codebase's `Ide_paths.code_store_dir` partition through `Ide_bridge.list_events`. The client retains that successful request's codebase on each normalized IDE event. A file action needs both an explicit valid relative file path and the same codebase as the selected workspace. A matching filename in another codebase does not qualify. This authority identifies a repository, not a source revision or an exact worktree snapshot.

The workspace-wide `/api/v1/activity/events` response supplies no per-event codebase authority. Its fileless events and events that merely contain `file_path` cannot be assigned to the selected repository. Payload strings, tags, Keeper names and an invented `run-default` workspace identity are not used to manufacture codebase provenance. Such rows remain in the timeline and retain operational links; they produce no Code action, file event count, or activity-derived line trace. Keeper/project views that cannot resolve a canonical codebase follow the same rule. Recovering repository-specific file navigation for those global events requires a future explicit backend provenance contract.

The existing thread, LSP and working-diff projections are preserved. This change does not establish codebase provenance for Board-derived thread anchors; that separate producer still uses its current `file:line` text projection.

## Verification

- Five meaningful existing/extended Vitest suites: 74 tests passed. Mounted tests change repository A to B with the same relative filename, keep global Task navigation working, and reject missing/foreign codebase file anchors. Existing Keeper Work and Reaction Thread suites remain green.
- Whole-dashboard TypeScript `--noEmit`, targeted production ESLint, Node syntax and diff checks passed. No local Dune or production dashboard build ran.
- `source-browser-receipt.json`: Chromium rendered the real source Activity panel against explicit synthetic HTTP fixtures. Repository A and B each expose exactly one matching file anchor while retaining four timeline rows. A codebase with no file events exposes zero file anchors while retaining both global history rows and their Task/Goal routes. The three source screenshots were captured and inspected.

The source browser uses Vite development transformation and a synthetic API fixture server. It is not installed MASC acceptance. Run with:

```sh
node scripts/ide-file-context-browser-probe.mjs dashboard /tmp/fresh-file-context-evidence
```

Installed acceptance of this change remains outstanding. This evidence closes one file-context defect, not all Workspace feature goals.

## Separate discoveries, outside this change

Existing UI/API connections were verified rather than treated as absent features:

- Reaction Thread reads Board posts and Keeper decisions. Notes/questions/comments are Board projections, with `file:line` text converted into anchors. There is no dedicated Memo/CodeComment authoring or persisted resolve action in that rail. The installed Board query returned zero posts, so populated comment creation/reply acceptance was not exercised.
- The Reaction Thread fetch runs once on mount and converts each source failure into an empty array. A note written while the rail stays open will not be fetched, and a failed source can appear empty. Refresh/load-state behavior is a separate bounded follow-up.
- Keeper Work reads current Keeper/task/goal stores and links planning routes; its current selected Keeper truthfully showed no active task/goal. Persistence Map shows current lifecycle and heartbeat, with Keeper/Telemetry links. These panels are implemented; a populated Task/Goal scenario was not created in live state for this discovery.
- The timeline reads the latest 50 workspace events, while Reaction Thread reads 200 decisions. Replay scrubs the loaded decision/thread window. The IDE has no older-history paging control, and its current UI does not expose the workspace API's total 1972-event count. Complete accumulated-history browsing needs a separate query/UI contract.

The distinction between repository history, file history and line authorship follows the explicit scopes in the [VS Code history documentation](https://code.visualstudio.com/docs/sourcecontrol/history); no new store or broad Workspace rewrite was introduced.
