# Conversation-first chat evidence

The default chat uses the existing `Origin_bare` mode as a reading layout. Metadata,
request receipts and journal rows are opt-in. Background Keeper requests remain
tracked but do not occupy this conversation's composer. The current progress line
keeps its activity and age; delivery uncertainty, failed interrupts and approval
questions remain visible.

## Checked

- Interpreted the actual layout, Markdown and supporting pure modules with OCaml
  5.5.1 (`ocaml`, `topfind`, `uuseg.string`, `alcotest`), without Dune or an executable
  build. Selected 12 existing layout tests; all passed. `layout-tests.txt` records
  the selected names and result.
- Ran the updated `test_oversized_entry_small_height_policy` again after the review
  fix. It covers User, Keeper and Inbound openings/sender identity and latest text
  at heights 3 and 4. `clipping-regression.txt` records the initial pass; the final
  12-test run also covers first-scroll consistency after removing phantom terminal spacing.
- Checked the actual layout implementation against its complete `.mli` in the
  interpreter. Checked changed OCaml file syntax with `ocamlc -stop-after parsing`
  and changed Python files with `ast.parse`. These are not a full application type
  check. `source-checks.json` records the source hashes.
- Independent source reviews covered transcript geometry/caching and status/row
  budgeting. Findings about decorative spacing hiding message content and about
  hidden turn-observation/interrupt failures and phantom scroll distance were fixed.
- `git diff --check` passed.

## Preview

[Interactive layout preview](../../design/tui/conversation-first-preview.html)
uses rows projected from the modified `Masc_tui_message_layout` and
`Masc_tui_markdown` source. `layout-preview.ml` is the fixture; `layout-preview.json`
is its output at 60, 96 and 144 terminal cells. It compares the detailed inline
projection with the new default. The HTML supplies preview typography and colors;
it is not a screenshot of the executable or a live runtime.

For design reference, the upstream [Codex chat surface](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget.rs)
separates conversation history and the composer. No upstream code was copied.

## Remaining verification

The updated status/queue and PTY scenarios have not been executed. A rebuilt TUI
must still be checked for live streaming, narrow/split panes, scrolling/search,
Ctrl-F/Ctrl-N/Ctrl-D, composer cursor placement, and unknown delivery/interrupt
outcomes. No local Dune build, CI dispatch, deployment or installed-binary change
was performed. The repository execution protocol requires ordinary source review
and separately selected execution checks; this evidence does not claim runtime
acceptance or release readiness.
