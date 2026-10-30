# Published parent propagation into #41131

Published #41131 `156d2bf8bf0b53903a2fd77258233a088ee02286` was cleanly merged
with published #41130 `0562bea26e960b19de8b531a0c09579b872de505`.
No independent product or test changes were made during this propagation.

The incoming `Masc_tui_lane_addons.removal_block_reason` interface and its
call in the composed TUI were checked with:

```sh
opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe
```

The focused compile passed. The Lane inventory i/d dispatch precedence and
read-only MSX retry changes from #41131 remain present. Web production/tests
are byte-identical to the published parent; its 55-test result is prior parent
evidence, not a new execution here. Native suites and PTY scenarios were not
rerun. Existing historical evidence is retained unchanged. This is not full CI,
release or deployed-runtime proof. The raw build log is retained exactly.
