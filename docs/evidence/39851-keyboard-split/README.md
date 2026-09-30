# #39851 keyboard scenario split

Baseline: `86751f610442e4d82992ebc54bf9eb8ba45ef6d2`.
Original monolith SHA256: `81a4f473c8386f4345e2f85e620ddf83257bccaff9385637ebbe43335978950f`.

The entry keeps the family registry and CLI. Shared PTY machinery lives in
`tui_keyboard_harness.py`; existing scenarios live in 23 area modules.
The default walk, family names, scenario descriptions, inputs, deadlines,
and assertions are unchanged. Consumers import the module that owns their
functions. Dune rules declare the complete local import closure explicitly.

## Source identity

Run from the repository root:

```sh
python3 scripts/verify-tui-keyboard-split.py --before-ref 86751f610442e4d82992ebc54bf9eb8ba45ef6d2 --output docs/evidence/39851-keyboard-split/move.json
```

`move.json` carries the full before/after definition name lists and family
listings: 372 definitions, missing 0, extra 0, changed body bytes 0;
44 families and 152 description occurrences have identical listing output.
This command lists scenarios without launching a TUI.

`move-comparison.json` independently compares the original bodies and all
146 existing Dune rule actions/aliases using the repository's stanza parser.
Only dependency declarations change in those rules.

## Dependencies and selection

`dune-dependency-proof.json` records the AST-derived helper closure and the
declared dependency set for each of the 146 affected rules.
No new glob is introduced. Existing unrelated glob declarations stay as they were.

`selector-proof.json` records the actual `select_sources` function from
`scripts/ci/run-edited-tests.sh` for each of the 24 new helper edits.
All expected runnable consumers appear in the selected suites. This is a
local selector probe, not a PR-check execution log.

`dependency-mutant.log` is an intentional failing control: removing the
shared harness dependency from a family rule makes the new
`test_family_rules_declare_every_imported_keyboard_module` assertion fail.

## Local tests and quality

`commands.json` gives the commands and exit codes. `focused-unit.log`
records 33 passing Python tests covering family selection, fixture shutdown,
Keeper selection, stall observations, and repeated artifact comparison.
The entry and the new verification script pass Ruff check and format check.

`quality-baseline.json` records the strict Python baseline comparison.
The original sources already have strict Pyright and Ruff diagnostics.
Whole changed-source strict Pyright reports 9490 errors before and after;
the new verification script has zero diagnostics. Ruff reports no undefined
names after the split. Existing scenario bodies are not reformatted and no
suppression is added. This is not a claim that the inherited strict baseline
is clean.

The artifact performance harness now hashes all three imported keyboard
helpers rather than the former monolith, and publishes each file digest
alongside the aggregate digest. The capture script loads the shared harness
and the module owning the schedule fixture explicitly.

## Runtime verification still required

The local Dune wrapper refused execution because the installed ocaml-msx
and ocaml-dos pins differ from the repository declarations. No PTY binary
was run locally, and no pin guard was bypassed.

`targeted-suites.json` lists all 146 affected aliases, partitioned into six
targeted Test batches. Current-head targeted results and the PR-check
selection log are required before review can establish runtime equivalence.
CI results will be recorded by run ID and head SHA after execution.

[Evidence] Source: repository commands and emitted JSON/log files above;
captured 2026-09-30 UTC. Confidence: High for source bytes and local Python
results; runtime equivalence remains unverified.
