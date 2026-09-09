# Prompt preset content inspection

Baseline: live local dashboard, `http://127.0.0.1:8935/dashboard/#settings?section=prompts`,
1440×1000 Chromium viewport. `baseline.png` is the pre-change deployment,
whose visible header reports `v0.35.1 · e361d0f1c0`. It is not a screenshot
of the new code. The source branch began at `b71a70026d`.

The initial viewport showed registry/library navigation, a large Librarian
contract, summary counters (244 registered, 2 overrides, 0 missing), and the
beginning of the prompt assembly panel. It did not expose full preset text.

The change places preset selection and one-click full source inspection near
the top of the registry. It uses the already-fetched effective templates,
labels source and base file, preserves unresolved variables, renders literal
text, and leaves editor drafts and save actions alone. The list intentionally
follows preset membership rather than the editor's search/source filters.
This is a template view, not a claim about a fully assembled runtime request.

Focused component interaction test command:

```sh
cd dashboard
pnpm test src/components/tools/prompt-registry-panel.test.ts
```

The initial 12-test run passed after correcting the new scenario to wait for
the asynchronous editor load. Static adversarial review confirmed source
semantics, escaping and draft preservation; keyboard access to the scrollable
source text was identified for repair. Final validation is recorded in the PR.

Remaining acceptance: CI and browser interaction against the built change,
including keyboard scrolling, mobile layout and switching presets. The
baseline screenshot and component tests do not prove deployed UI completion.
The TUI counterpart and the other product acceptance rows remain open.

## Runtime configuration observation

A subsequent read of `/api/v1/prompts` found the live `keeper` source was
`override`, with effective SHA-256
`efb476e71b57c193e9e79ae9aa95f90535ef2244ea4c70ff15b65016e8c76272`.
It did not contain the newly merged purposeful-work sections. Updating the
base markdown alone would therefore leave this effective body unchanged.
The preset view now explains this precedence for every overridden entry.

Two attempted update requests were rejected with HTTP 401 (`missing_token`).
No runtime update was confirmed or applied by these requests. The user then
specified worktree-only work; implementation and validation continue in this
branch. The runtime observation is evidence of a configuration mismatch, not
proof of new Keeper behavior.

## CI-built browser acceptance

PR checks now build the Dashboard and upload `dashboard-preview-<head>-<attempt>`.
The archive includes `preview-provenance.json` with the actual checkout commit
(the PR merge commit), PR head, run identity and per-file SHA-256 hashes.
After downloading that artifact into a worktree, run:

```sh
node scripts/verify-prompt-preset-preview.mjs \
  /path/to/downloaded-preview EXPECTED_PR_HEAD \
  http://127.0.0.1:8935 /path/to/evidence
```

The browser loads CI assets while using live GET responses. All non-GET/HEAD
requests and WebSocket connections are blocked; service workers are disabled. The script verifies every asset hash before navigation,
compares every effective prompt body in the full preset, switches to System
rules, checks keyboard focus and mobile overflow, and writes desktop/mobile
screenshots plus a receipt. This is frontend verification over a live backend,
not a production deployment claim. The script has not yet run against a built
artifact at this commit; syntax validation alone does not prove acceptance.
