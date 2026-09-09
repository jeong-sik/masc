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
