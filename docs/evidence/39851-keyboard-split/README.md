# #39851 keyboard scenario split

Current pre-split parent: `ccef0a8dab4d54e64853f0a73216d268a07d89a5`.
Original monolith SHA256: `890a9e80adc6e6ddfd3346c76780992da18780aec0c783da334b32a21c768153`.
The split branch incorporated this parent in `4a6b5c275720fd83cb3b21b6b170bd004d69ef1c`.

The entry keeps the family registry, CLI and explicit public helper exports
used by tracked capture/profile scripts. Shared PTY machinery lives in
`tui_keyboard_harness.py`; existing scenarios live in 23 area modules.
New consumers import the module that owns their functions. Existing capture
sources retain their imports and recorded evidence provenance.

## Current source identity

Run from the repository root:

```sh
python3 scripts/verify-tui-keyboard-split.py --before-ref ccef0a8dab4d54e64853f0a73216d268a07d89a5 --output docs/evidence/39851-keyboard-split/move.json
```

The regenerated `move.json` compares this current pre-split parent with the
entry and all extracted owners: 373 definitions, missing 0, extra 0, changed
body bytes 0. The listing has the same 44 families and 152 description
occurrences. This command lists scenarios without launching a TUI.
The public import declarations do not change any definition body.

## Current Python verification

`review-followup-commands.json` and `review-followup-unit.log` record the
current commands and results. The focused Python suites include the tracked
capture helper contract, construction of both #39827 capture fixtures with
the terminal call mocked, and search-count Board fixture construction up to
a mocked terminal boundary. These tests do not run a native TUI or claim
that a screenshot was captured.

The capture contract resolves the helpers used by the retained About/Info,
profile and browser capture sources. The regression suite declares these
source files and the search-count consumer in its Dune dependencies.

## Original extraction receipts

The other files in this directory were recorded for the original extraction
from `86751f610442e4d82992ebc54bf9eb8ba45ef6d2`. Their original source refs,
command lines and measurements remain in the receipts:

- `move-comparison.json`: original definition-body and 146 Dune rule action comparisons.
- `dune-dependency-proof.json` and `selector-proof.json`: original import closure and selector probes.
- `dependency-mutant.log`: original deliberately removed dependency failing control.
- `commands.json`, `focused-unit.log` and `quality-baseline.json`: original 33-test and static-tool observations.
- `targeted-suites.json`: the 146 aliases partitioned for targeted execution.

The current source equivalence result is the regenerated `move.json` above.
The original quality and dependency measurements are scoped to their recorded
sources; they are not relabelled as executions of the refreshed branch.

## Runtime verification still required

No native TUI or local Dune build was run for this follow-up. The original
local attempt stopped at the installed ocaml-msx/ocaml-dos pin guard and did
not bypass it. Runtime equivalence requires evidence from the applicable
current-head checks and targeted executions; no CI was dispatched here.
