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
- Occurrence observation component tests: 13 PASS.
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

A later independent review found that retained_terminal_wake is still pending
when a declaration is cancelled after ownership transfer. retained-before.log
records the added case failing (1/12) before the decoder repair; components.log
records the repaired 12-case run. These are decoder checks, not a backend
transfer/cancel execution or a real provider failover experiment.

## Missing-stimulus review response

MASC review [5650416953](https://github.com/jeong-sik/masc/pull/46092#pullrequestreview-5650416953)
identified a supported retained receipt with null stimulus_id that aborted the
whole row-list decode. missing-stimulus-before.log records the added component
case failing (1/13); receipt-page-before.log records the actual source-extracted
consumer failing three mixed-page decisions (3/9) before the repair.

The repaired decoder admits the producer's unrecognized_receipt +
missing_stimulus_id combination as Unknown after checking the retained
schedule/instance/Keeper/post identities and rejecting bound or positive
reaction evidence. It does not catch all row errors or drop rows. Strict
malformed-field and mismatched-identity rejection remains unchanged.

Run the direct-consumer probe from the repository root:

```sh
python3 docs/evidence/2026-10-26-schedule-behavior-audit/run_receipt_page.py --output docs/evidence/2026-10-26-schedule-behavior-audit
```

receipt-page.log records 13 PASS decisions: both row orders, omitted stimulus,
and negative controls for cross-occurrence evidence, malformed summary boolean,
duplicate/missing core identity, target/instance mismatch, positive progress,
matched pending queue, bound reaction stimulus and remaining post identity.
receipt-page.json hashes all consumed sources. The probe compiles the real
Tui_decode_fields module/interface, exact Json_util helpers and Json_kind,
Schedule_contract_values, observation decoder, production schedule_row record,
actual runner-hold decoder and complete decode_schedule_row/decode_schedule_rows
source. Only module namespace aliases and type/function extraction isolate it;
no parsing algorithm is stubbed. Synthetic mutations of one archived real row
exercise the failure inputs. This proves the decoder consumer, not a fresh
backend run or an executed TUI screen.

The earlier retained-before.log remains a historical 1/12 failure; its repaired
12-case run preceded this added thirteenth case. Current components.log records
28 domain / 13 observation tests plus the 14-row replay and 8 selection checks.
