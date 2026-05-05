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
- The source documents disagree on the aggregate audit total: 206 vs 214.
- The source documents claim 206 findings for the current catalog total, but
  only 19 finding IDs are itemized in the checked artifacts.
- `consistency_findings: 1 open=1` preserves the unresolved 206-vs-214
  aggregate mismatch as a separate gate.
- `source_artifacts` is `INCOMPLETE` while the logical
  `prompt_corpus/GOAL_LOOP/...` source paths are not backed by checked files.
- `--require-complete-catalog` intentionally exits non-zero until the full
  row-level corpus is attached or checked in.
- `--require-consistency-resolved` intentionally exits non-zero until the
  aggregate audit count is reconciled.

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

Expected key fact: this exits non-zero while the 206-vs-214 consistency finding
is open. Resolving the source-of-truth aggregate should make this command pass
without requiring code changes.

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
`source_aggregate_claim_sources_verified=5`. With the checked catalog's
digest metadata, it should also show `source_identity_status=COMPLETE` and
`source_identity_checks_verified=12`. The non-blocking
`source_structured_item_ids_total` and
`source_structured_item_ids_uncataloged` fields expose broader structured IDs
that need separate triage instead of silently expanding the strict GOAL LOOP
audit catalog. `source_structured_item_id_families` groups that backlog by ID
family so it can be assigned to the right follow-up catalog. `--require-complete-catalog`
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
