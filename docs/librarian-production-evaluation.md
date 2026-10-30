# Measure the production Librarian working state

`masc-librarian-continuity compare-production` uses
`Keeper_librarian_runtime.infer_working_state`, the same volatile inference
entrypoint the Queue uses. It measures the configured Librarian exact-output
lane rather than the separate summarization prompt used by `compare`.

This is an offline measurement with explicitly synthetic input. It does not
publish Memory, a live continuity frontier, queued work or a read cursor. The
command creates a new evaluation workspace beside the report and retains its
diagnostics. It does not discover or read private Keeper conversations.

Use an executable containing this command and a configuration declaring the
actual exact-output lanes and credentials:

```sh
masc-librarian-continuity compare-production \
  --input benchmarks/data/librarian_production_synthetic.json \
  --output /path/to/new-report.json \
  --config /path/to/runtime.toml \
  --prompts-dir /path/to/config/prompts \
  --runtime provider.answer-model
```

`--runtime` selects the common Agent Core **answer** provider. The configuration's
`runtime.exact_output_lanes.librarian_exact` selects the production Librarian
API/CLI candidates. The command publishes that lane registry using the same
immutable configuration observation used to initialize the runtime table, with
the existing mandatory-lane and catalog policies. It does not synthesize a lane.
`--prompts-dir` selects the production prompt files explicitly; the fresh
process does not import an operator's live prompt overrides. The report records
the actual resolution and rendered base prompt from the inference pass.

Both arms use the first configured TypeSafeAI judge destination. Missing judge
credentials or failures are recorded as failures, never as a zero probability.
No second judge or semantic acceptance threshold is substituted.

## Input and comparison

The dataset has exactly `provenance` and `cases`. Provenance must be
`["Synthetic"]`. Every case has exactly:

| Field | Meaning |
| --- | --- |
| `id` | Unique nonblank case identity |
| `source` | Complete `Keeper_librarian_input_capture` value, including the full prefix and actual typed Memory/host context |
| `previous_state` | Explicit prior text or `null`; opaque context, with no invented earlier source coverage |
| `unread_messages` | Explicit actual unread codec values; coordinates and original message hashes must match this prefix |
| `suffix` | Future messages in the complete capture message codec |
| `question` | Common nonblank evaluation question |

The command derives the actual inference input once from the frozen prefix.
It verifies unread coordinates and hashes, excludes those original messages,
and excludes pinned request context as the Queue's source selector does.
Historical task message offsets follow the retained messages; original trace,
atom spans and attribution remain intact. All-hole inputs still ask the actual
lane for a continuation with explicit holes. The report retains the full source
and the exact selected input separately.

The inference lane receives the selected prefix, prior state and explicit holes.
It cannot see the future suffix or the evaluation question. On success, the
production snapshot codec saves the state with the full prefix's coverage and
holes, reloads it, and validates restoration against that prefix plus the suffix.
Pinned context survives restoration. A changed prefix or failed storage step is
recorded; it does not become a synthetic successful restoration.

The baseline answer sees the full prefix plus suffix and prior state. The
restored answer sees the loaded new state plus the restored suffix. Current
Memory, Keeper instructions/goals, pending working context, tool/counterpart
observations, question, answer provider and judge are shared. Historical task
spans attached to the covered prefix travel through the new state. Both judges
receive the same full reference and question.

## Read the evidence

The authoritative artifact is the JSON report, schema
`masc.librarian-production-working-state.v1`. Optional blob publication is only
a copy. The report includes input/configuration/binary identities, the isolated
workspace, per-case progress, source selection, exact prompt preparation,
accepted API/CLI slot, unread holes, snapshot artifact, answer requests and raw
JEV outcomes. Failures retain their actual reports and exhausted-provider
refusal evidence; no diagnostic text grants unread authority.

Prompt preparation records the actual run ID, template resolution, variables,
rendered base prompt and output schema before preflight. It is **not proof of
provider wire bytes or dispatch**; CLI candidates append schema instructions.
Answer request observations likewise describe preparation. The accepted slot
identifies the candidate whose answer the Librarian accepted.

The start transition is saved before inference. Each returned outcome is saved
before the next effect. A report write failure stops the experiment. Cancellation
propagates; the last report can remain `started`, which is not a completed or
successful inference. Failed inference/restoration still permits the baseline.
An answer or judge failure in one arm does not suppress the other.

`all_cases_scored` and exit code 0 mean both arms received judgments. A probability
of 0 is still a successfully recorded judgment. These fields do not assert that
continuity quality passed.

Synthetic boundary coordinates prove only this experiment's storage/projection
consistency. The authored loopback tests and bounded source probes are separate
from a completed production-model measurement. Real official-client fragments,
installed continuity across turns, visible I4 surfaces and configuration
transition evidence remain separate requirements before removing the global
history-mark policy in issue #38062.
