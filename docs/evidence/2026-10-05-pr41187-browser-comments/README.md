# Browser path comments and administrative raw-save instructions

Baseline #41187 `6e22126d8325d61cc627461a8e05402b70fc9fc4`; review comments4179553371 and4179553373. The administrative examples omitted required `expected_source_path`; both now carry the original GET's `path` together with its `source_revision`. The documented jq expression was executed on fixture JSON and preserved both original values with the edited text. Server GET/parser/CAS source was checked; no live administrative write was sent.

The accepted flat Browser path migration removed assignments and rendered new ones, discarding inline operator notes. The new regression reproduced missing `# pinned driver` (16 existing cases passed, one failed). The repair qualifies the original structural assignments in place, retaining key quoting, value spelling, indentation and adjacent/inline comments. It adds the activity flag with the existing nested editor, and subsequent edits use that editor for ordinary/dotted tables so they do not redeclare the migrated namespace. Unsupported inline shapes retain their previous refusal. Final Browser configuration equality still rejects unintended changes.

The focused executable passed all17 cases, including quoted flat path keys, inline/adjacent comments, configured paths, other backend flags and a second toggle without invalid table redeclaration. Independent source review read the structural scanner, key/header parser and nested-editor contract. No new parser, provider call or config-writer API was introduced.

```sh
opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build test/test_tui_browser_activity.exe
_build/default/test/test_tui_browser_activity.exe
```

Both meaningful failure and final success logs are copied byte-for-byte; checks.json pins source and executable identity. This is focused native state/edit behavior, not a new TUI PTY, full suite, hosted CI or release result. TerminalBench remains unrun.
