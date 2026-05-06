# GOAL LOOP fixture replay

This fixture bundle is a local, deterministic replay of the startup evidence
used by the GOAL LOOP tooling tests.  It proves that Observe, Orient, Decide,
Act linkage, Verify, and aggregate status stay wired together without needing a
live production log.

Run from the repository root:

```bash
python3 scripts/decide_goal_loop_findings.py \
  test/fixtures/goal_loop/orient.startup.json \
  --act-map test/fixtures/goal_loop/act-map.startup.json \
  > /tmp/goal-loop-decide.json

python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json test/fixtures/goal_loop/orient.startup.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json test/fixtures/goal_loop/verify.fail.json \
  --loop-iteration "#fixture" \
  --format text
```

Expected key facts:

- `overall_status` is `critical`.
- Decide reports `act_linked_count=5` and `act_missing_count=0`.
- Act is no longer critical in the fixture: every startup decision has at least
  one linked PR artifact.
- Verify remains `FAIL` because the startup replay is pre-ACT evidence, so the
  loop must not be marked complete until a post-ACT live verify passes.
- `phases.verify.summary.violation_kinds` includes
  `post_act_verify_pending`, making the live-runtime proof gap machine-visible
  in aggregate status output.
- A generic Verify `PASS` is not closeout evidence. Completion requires
  `post_act_verify=true`, an accepted live-runtime `evidence_kind`, a concrete
  `evidence_source`, an explicit `evidence_window_start` /
  `evidence_window_end`, and `checked_at` metadata from the post-ACT
  collection.

Use the JSON status form when another tool needs to consume the replay:

```bash
python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json test/fixtures/goal_loop/orient.startup.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json test/fixtures/goal_loop/verify.fail.json \
  --loop-iteration "#fixture"
```

Validate that the fixture's ACT artifacts point at known PR numbers:

```bash
python3 scripts/validate_goal_loop_act_map.py \
  test/fixtures/goal_loop/act-map.startup.json \
  --known-prs-json test/fixtures/goal_loop/known-prs.startup.json \
  --require-pr-ref \
  --fail-on any
```

For live validation, capture a current PR snapshot first and pass that file as
`--known-prs-json`.

Replay the external 206-audit claim catalog through Orient:

```bash
python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --audit-source-root . \
  > /tmp/goal-loop-orient-audit.json

python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --audit-source-root . \
  --format text
```

Expected key facts:

- `audit_catalog` is `INCOMPLETE`.
- The manifest covers all 12 prompt-supplied source documents.
- The source documents reconcile the aggregate audit total as 206 baseline
  audit findings plus 8 live-log `NEW_FINDING` items, yielding the 214
  integrated total.
- The source documents claim 206 findings for the current catalog total, but
  only 19 finding IDs are itemized in the checked artifacts.
- `aggregate_reconciliations: COMPLETE verified=1 failed=0` validates the
  206 + 8 = 214 arithmetic.
- `consistency_findings: 1 open=0` preserves the prior aggregate mismatch as a
  resolved, machine-checkable record.
- `source_artifacts` is `INCOMPLETE` while the logical
  `prompt_corpus/GOAL_LOOP/...` source paths are not backed by checked files.
- `--require-complete-catalog` intentionally exits non-zero until the full
  row-level corpus is attached or checked in.
- `--require-consistency-resolved` passes when the resolved reconciliation is
  present.

Validate that source-artifact gap directly:

```bash
python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --audit-source-root . \
  --require-source-artifacts
```

Expected key fact: this exits non-zero until the catalog's source files exist
under `prompt_corpus/GOAL_LOOP/...`. That is separate from the row-level
`--require-complete-catalog` gate.

Validate the aggregate-count consistency gate directly:

```bash
python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --require-consistency-resolved
```

Expected key fact: the checked fixture records
`audit_total_214 = audit_total_206 + new_findings_live_8`, so this command
passes for the resolved catalog. It will exit non-zero if the consistency
finding is reopened.

When the full 206-row strict corpus path is unknown, discover likely candidates
before validating one:

```bash
python3 scripts/discover_goal_loop_strict_row_corpus.py \
  <SEARCH_ROOT_OR_ARTIFACT> \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --require-found \
  --format text
```

Expected key fact: this separates marker hits from validated strict corpora.
`--require-found` exits non-zero unless at least one candidate passes the same
strict corpus validator used by Orient. A positive result is still only an
intake signal; feed the selected corpus into Orient next.

When the full 206-row strict corpus is available, feed it into Orient instead
of using it only at closeout:

```bash
python3 scripts/validate_goal_loop_strict_row_corpus.py \
  <STRICT_ROW_CORPUS_JSON> \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --require-valid \
  --format text
```

Expected key fact: this is a fast intake check for the candidate artifact
shape. It must report `strict_row_corpus: VALID rows=206 expected=206
errors=0` before the corpus can be useful in the full Orient replay below.
When `--audit-catalog` is supplied, every row source path must also match one
of the catalog `external_sources`, and every row line ref must be within that
source line count when the manifest records one. The explicit source-row
candidate inventory is not a strict corpus; if supplied to this command it must
fail with `source_row_candidate_inventory_is_not_strict_corpus` because it is
`INCOMPLETE` and does not contain a top-level `findings` array.

```bash
python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --strict-row-corpus <STRICT_ROW_CORPUS_JSON> \
  --require-complete-catalog \
  --format text
```

Expected key fact: `--strict-row-corpus` validates the same contract described
by `test/fixtures/goal_loop/strict-row-corpus-contract.json`. A valid corpus
becomes the strict Orient catalog basis, so `audit_catalog` can report
`COMPLETE itemized=206 expected=206`. Invalid corpora, including duplicate
finding IDs or `/Users/...` source paths, do not replace the current 19-row
catalog and keep `--require-complete-catalog` failing.

Validate against a local external source root without checking the documents
into the public repository:

```bash
python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --audit-source-root <GOAL_LOOP_SOURCE_ROOT> \
  --audit-source-strip-prefix prompt_corpus/GOAL_LOOP \
  --require-source-artifacts
```

Expected key fact: this can pass locally when the 12 prompt-supplied source
files exist under `<GOAL_LOOP_SOURCE_ROOT>`. The source-artifact summary should show
`source_artifacts_resolved=12`, `source_itemized_finding_ids_total=19`,
`catalog_itemized_finding_ids_total=19`, zero source/catalog ID mismatch,
`source_aggregate_claim_status=COMPLETE`, and
`source_aggregate_claim_sources_verified=6`. It should also show
`source_aggregate_reconciliation_status=COMPLETE`,
`source_aggregate_reconciliations_verified=1`, and
`source_aggregate_reconciliations_failed=0`. With the checked catalog's digest
metadata, it should also show `source_identity_status=COMPLETE` and
`source_identity_checks_verified=12`. The non-blocking
`source_structured_item_ids_total` and
`source_structured_item_ids_uncataloged` fields expose broader structured IDs
that need separate triage instead of silently expanding the strict GOAL LOOP
audit catalog. `source_structured_item_id_families` groups that backlog by ID
family so it can be assigned to the right follow-up catalog.
`source_structured_item_ids_uncataloged_occurrence_samples` preserves concrete
source path and line evidence for the uncataloged IDs. `--require-complete-catalog`
can still fail because the row-level 206 corpus is incomplete.

Use the catalog-enriched Orient output in aggregate GOAL LOOP status when
checking whether the goal can be closed:

```bash
python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json /tmp/goal-loop-orient-audit.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json test/fixtures/goal_loop/verify.fail.json \
  --loop-iteration "#fixture"
```

Expected key fact: `phases.orient.summary.audit_catalog` preserves the
source-document coverage, missing row count, source/catalog itemized-ID counts,
and open consistency finding; the Verify phase still exposes
`post_act_verify_pending` in `violation_kinds`.

Use the status JSON as input to the closeout gate before marking the Goal
complete:

```bash
python3 scripts/verify_goal_loop_logs.py \
  /tmp/goal-loop-orient-post-act.json \
  --post-act-verify \
  --evidence-kind live_runtime_logs \
  --evidence-source <POST_ACT_LOG_OR_ENDPOINT> \
  --evidence-window-start <POST_ACT_WINDOW_START> \
  --evidence-window-end <POST_ACT_WINDOW_END> \
  --checked-at <ISO8601_TIMESTAMP> \
  > /tmp/goal-loop-verify-post-act.json

python3 scripts/goal_loop_status.py \
  --observe-json test/fixtures/goal_loop/observe.startup.json \
  --orient-json /tmp/goal-loop-orient-audit.json \
  --decide-json /tmp/goal-loop-decide.json \
  --verify-json /tmp/goal-loop-verify-post-act.json \
  --loop-iteration "#fixture" \
  > /tmp/goal-loop-status-audit.json

python3 scripts/goal_loop_completion_audit.py \
  /tmp/goal-loop-status-audit.json \
  --structured-id-triage test/fixtures/goal_loop/structured-id-triage.external-claim.json \
  --row-corpus-discovery test/fixtures/goal_loop/row-corpus-discovery.external-claim.json \
  --require-complete \
  --format text
```

When a candidate 206-row corpus is available, pass it through the same closeout
path by first replaying it through Orient. This is the acceptance check that
turns the supplied corpus from a shaped artifact into replay evidence:

```bash
python3 scripts/orient_goal_loop_logs.py \
  test/fixtures/goal_loop/observe.startup.json \
  --audit-catalog test/fixtures/goal_loop/audit-corpus.external-claim.json \
  --strict-row-corpus <STRICT_ROW_CORPUS_JSON> \
  --audit-source-root <GOAL_LOOP_SOURCE_ROOT> \
  --audit-source-strip-prefix prompt_corpus/GOAL_LOOP \
  --require-source-artifacts \
  --require-consistency-resolved \
  --require-complete-catalog \
  > /tmp/goal-loop-orient-audit.json
```

Then run the same closeout gate:

```bash
python3 scripts/goal_loop_completion_audit.py \
  /tmp/goal-loop-status-audit.json \
  --structured-id-triage test/fixtures/goal_loop/structured-id-triage.external-claim.json \
  --row-corpus-discovery test/fixtures/goal_loop/row-corpus-discovery.external-claim.json \
  --strict-row-corpus <STRICT_ROW_CORPUS_JSON> \
  --require-complete \
  --format text
```

Expected key fact: this exits non-zero until every completion criterion passes.
With the current fixture and external source manifest it reports `BLOCKED`
because the strict row-level catalog is incomplete and post-ACT Verify is still
pending. The aggregate mismatch is resolved only while
`aggregate_reconciliations: COMPLETE verified=1 failed=0` remains true. The
broader structured-ID criterion passes only when the triage manifest covers
every uncataloged family and expected occurrence count. The row-corpus
discovery manifest records the unsuccessful search for a full 206-row strict
corpus and attaches that evidence to `strict_row_level_catalog_complete`, but
it does not satisfy the criterion. A supplied strict-row corpus is validated
against `test/fixtures/goal_loop/strict-row-corpus-contract.json`: 206 unique
rows, logical `prompt_corpus/GOAL_LOOP/...` source paths, positive line refs,
catalog external-source binding, catalog line-count bounds when available,
severity/actionability, and replay expectations. A valid supplied corpus still
does not close the blocker unless the status input was produced from Orient
with the same corpus and reports the strict row-level catalog as `COMPLETE`
with 206 itemized findings and zero missing rows.

When the Verify input is replaced with a live post-ACT artifact that carries
the required evidence-window metadata, `post_act_verify_complete` can pass.
The closeout audit must still remain `BLOCKED` until
`strict_row_level_catalog_complete` passes for the full 206-row corpus.
