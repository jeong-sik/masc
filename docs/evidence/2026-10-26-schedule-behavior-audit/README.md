# Scheduled Job component evidence

See the [whole-feature behavior audit](../../audits/2026-10-26-scheduled-job-behavior-audit.md).

Run from the repository root:

```sh
python3 docs/evidence/2026-10-26-schedule-behavior-audit/run_components.py --output docs/evidence/2026-10-26-schedule-behavior-audit
```

The script compiles actual leaf production sources directly with the installed
OCaml compiler and package toolchain. It does not invoke Dune or build the server/TUI.
The sole consumed Json_util binding, reject_unknown_fields, is extracted from its
production source; the selection probe extracts the complete production row/page
records and chat_schedule_entries, uses the actual Schedule_domain/Time_codec and
an existing test row, and provides only the Masc namespace alias. No alternative
selection algorithm or UI wording/layout assertions are used.

Results in components.log:

- Existing Schedule_domain tests: 28 PASS.
- Occurrence observation component tests: 11 PASS.
- Archived, unmodified real backend producer rows: 14 matching decisions.
- Source-extracted chat selection: 8 PASS.

receipt.json records SHA-256 for consumed sources and the 14 replay decisions.
base_head identifies the checkout's starting commit, while source_sha256 identifies
the actual worktree inputs. It is not an exact-commit integration execution claim.
Compiler temporary directories are deleted after the run; absolute temporary paths
in the log are command provenance, not retained executables.

The producer rows are historical inputs from the prior
[schedule-drain projection evidence](../2026-10-25-schedule-drain-projection/README.md).
This execution checks the new decoder against those rows, not a fresh backend run.
The component log includes findlib duplicate-interface warnings for digestif.cmi
from installed packages; these are compiler environment warnings, not production incidents.

Not proven: whole-program typecheck, current backend suite, actual TUI execution,
provider/model execution, destination delivery, installed binary or deployment.
