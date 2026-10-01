# #39851 keyboard scenario split

The entry keeps the family registry, CLI and explicit public helper exports used by tracked capture/profile scripts. Shared machinery lives in `tui_keyboard_harness.py`; area modules own scenario bodies. Client/Connector consumers import their owners directly. Remaining legacy standalone/capture consumers use explicit compatibility exports; their required helper surface and complete entry import closure are recorded in `helper-closure-repair.json` and declared in Dune. The generic `press_and_settle` helper belongs to the harness.

## Current source checks

`current-python-checks.json` records 41 passing local Python tests for source verification, scenario selection, tracked capture helper construction, fixture shutdown, selection, stall observation and artifact comparison. Native terminal calls in the capture/search-count checks are mocked. No native TUI, Dune build, screenshots or CI execution is established by these tests.

The verifier now inventories every non-import top-level executable statement as well as definition bodies. The inventory detects changed content or multiplicity of constants, annotated assignments, side-effect statements, duplicates and the entrypoint guard. It does not compare statement order or owning module, so it does not certify equivalent execution ordering. Imports are ownership wiring and are covered separately by consumer/import tests; the report is not a proof of arbitrary import side-effect equivalence.

## Current differences from the recorded pre-split source

Run from the repository root:

```sh
python3 scripts/verify-tui-keyboard-split.py --before-ref ccef0a8dab4d54e64853f0a73216d268a07d89a5 --output /tmp/keyboard-current-source-delta.json
```

On reviewed source `ef1d61b2024196bb6450d4e48164a5e519833ef5` plus this verifier correction, this command **exits 1**, because the current scenarios have evolved after the extraction. The retained `current-source-delta.json` records 373 prior definitions versus 380 current definitions: zero missing, seven added and 19 changed bodies; one removed and two added module statements; scenario listings also differ. Each current input file is bound by SHA256. These differences require source review and are not certified as a mechanical-equivalence pass. The earlier claim that the current tree reproduces a zero-difference 373-definition proof is withdrawn.

## Historical receipts

`move.json` and `review-followup-commands.json` are historical records of an earlier follow-up. They are retained without relabelling their successful commands as current-head results. They do not establish equivalence of today's changed scenarios.

The original extraction records used `86751f610442e4d82992ebc54bf9eb8ba45ef6d2`: `move-comparison.json`, `dune-dependency-proof.json`, `selector-proof.json`, `dependency-mutant.log`, `commands.json`, `focused-unit.log`, `quality-baseline.json` and `targeted-suites.json`. Their original refs and scope remain in the artifacts. No current native runtime equivalence is claimed.
