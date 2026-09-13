# Reaction Thread source refresh

Board posts and Keeper decisions now load independently. Each source displays loading, successful load count, or failure, with the last successful observation time when available. A failed refresh keeps the last successful source snapshot visible; a failed first load says that no successful data exists. A source can be refreshed or retried without restarting the other source. The empty-window message is shown only when both sources loaded successfully. Retained data stays available when no codebase is selected; source loading does not claim repository provenance.

Each request has an AbortController and ignores completion after cancellation. Replacement requests and unmount abort the former read. Board's API now forwards that signal; both API readers reject missing/non-array list envelopes instead of presenting them as empty success. Existing row normalization remains unchanged.

The rail subscribes to the existing server-push router and its debounce scheduler. Explicit Board events invalidate Board; decision-family events and Keeper turn completion invalidate Decisions. Reconnect invalidates both. Only a mounted subscriber on an IDE route requests refresh. Subscription cleanup prevents later scheduled invalidations from refreshing an unmounted rail. No periodic polling interval or runtime budget is introduced.

## Evidence

- Four suites passed, 318 tests: mounted Reaction Thread, Board API, dashboard API, and server-push routing. Cases cover initial loading, independent failure and recovery, retained data, malformed envelopes, overlapping requests, unmount, and source-specific event refresh. Existing content/navigation/replay tests remain included.
- Whole Dashboard TypeScript `--noEmit`, targeted production ESLint, Node syntax, and `git diff --check` passed.
- `receipt.json` and five screenshots show Chromium rendering the actual source component with synthetic HTTP responses. Board loads while Decisions fails; Board's subsequent failure retains its note; manual retry produces a real rendered decision card; existing event routing refreshes both sources independently. The mobile capture at 390px has no document horizontal overflow. Screenshots were directly inspected.
- `initial-test-failures.txt` retains two initial harness failures: a selector that assumed the workspace scope was the first source row, and a new router test without fake-timer setup. Both harness issues were corrected before the passing suite run.

This is source browser evidence using Vite development transformation and explicit synthetic API/push fixtures. It is not installed MASC acceptance, real Board mutation, autonomous Keeper activity, or actual transport reconnect acceptance. No local Dune or dashboard production build ran.

## Reproduce

```sh
node scripts/ide-conversation-browser-probe.mjs dashboard /tmp/fresh-conversation-source-evidence
```

The probe owns its Vite server, browser, output directory and synthetic responses. It performs no live runtime mutations.

## Remaining scope

Board-derived file/line provenance, authoring, persisted comment resolution, older-history pagination and complete history totals remain separate work. This change improves source freshness and failure truthfulness; it does not establish those features or the full Workspace goal.
