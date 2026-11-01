# Selected Codex Keeper inference declarations

PR [#47146](https://github.com/jeong-sik/masc/pull/47146) carries reasoning effort
and the model protocol-idle declaration from the selected immutable runtime into
the Keeper adapter. A runtime ID remains an observation/session identity; a later
catalog lookup cannot replace this selected request's declarations. Hooks can
override or clear effort, and the native client's existing model-list admission
still determines its supported tier. The separate admission/write timeout and
account-home behavior are unchanged.

Both recorded workflows actually concluded **FAILURE**. The six new negative
cases change from FAIL to PASS; one existing completion-evidence case remains
FAIL. This bundle does not describe a successful whole regression.

## Actual executions

Workflow **Test**, ref `fix/codex-selected-inference-20261101`, explicit minimal
dispatches:

| Role | Run | Actual checkout head | Requested suites | Result |
| --- | --- | --- | --- | --- |
| Parent-production baseline | [41282920501](https://github.com/jeong-sik/masc/actions/runs/41282920501) | `8602b0e1d906a633481411da013d64c7b6c63214` | `test_keeper_codex_current_context` | FAILURE: 33 PASS / 7 FAIL |
| Candidate | [41283161863](https://github.com/jeong-sik/masc/actions/runs/41283161863) | `cbf6196ffa5b2e9067548a8d5a7fc5db825dba6f` | `test_keeper_codex_current_context,test_keeper_codex_blank_system_prompt,test_official_client_claim_cause` | FAILURE: 54 PASS / 1 FAIL |

The candidate consists of context 40 PASS / 1 FAIL, blank-prompt 2 PASS / 0 FAIL,
and claim-cause 12 PASS / 0 FAIL. These are suite counts from that one execution.
They are not added to the baseline.

The baseline's `lib/`, `packages/agent_core/` and `config/` trees equal PR parent
`3aaa7542f97e40f08214f175f601f398afebce84`. Its 40 context cases are present in the
candidate, in the same order: 33 PASS remain PASS, six FAIL become PASS, one FAIL
remains FAIL, and no PASS becomes FAIL. The candidate adds one public-driver
callback case, which passes. Its test tree also adds the two required selected
model arguments to the adapter call; the two test trees are **not identical**.
[fixture-delta.json](fixture-delta.json) retains the exact context-fixture delta
as JSON-encoded original lines, including their line endings. Its raw digest
binds the decoded Git diff; encoding avoids treating patch context spaces as
new evidence-file trailing whitespace.

The five negative reasoning cases directly observe the child's first native
`turn/start`: selected High becomes Low or absent, selected absent becomes Low,
and selected explicit None becomes Low after replacement/removal of declarations
or removal of the runtime. Their baseline assertions fail before the subsequent
resume checks. The sixth negative case receives a typed idle timeout after
`turn/start` acceptance: a selected zero/unbounded declaration was replaced by
the new catalog's 0.025-second window. The child deliberately stays silent for
0.25 seconds; these are fixture inputs, not new production limits.

On the candidate, those cases complete both Start and Resume. Hook override,
hook clearing and account-advertised tier adjustment are controls that pass in
both executions. The added public `run_named` case reloads the same runtime ID
inside `on_runtime_attempt`, after candidate selection, and observes the original
High at the actual native writer.

The remaining failure is `completion evidence without a Keeper boundary keeps
every atom`: both executions return a message list different from the exact
completion evidence. Its case and relevant production projection are unchanged
by this inference repair. Source inspection points to `Host.project_source`
attaching Keeper unread context after the completion-evidence fast path; that
causal explanation is source inference and needs its own native-writer repair.
The assertion is retained and has not been weakened or skipped.

## Provenance

[manifest.json](manifest.json) binds workflow/ref/head, actual checkout receipts,
suite counts, raw and selected capture digests and their distinct byte streams.
[baseline.txt](baseline.txt) and [candidate.txt](candidate.txt) retain every actual
timestamped case row, failures, expected/received values, timeout, checkout and
targeted-runner summaries. ANSI/BOM normalization makes them derivatives; routine
build output and decorative duplicate case rows are omitted. Full raw job logs
remain in ignored `artifacts/issues-oldest-20261101/codex-selected-inference/`.

[case-comparison.json](case-comparison.json) maps each case's group/index from its
actual log to the full literal name in that head's historical fixture source.
Alcotest's ellipsized display is not used as identity. Common keys are encoded as
UTF-8 compact JSON arrays of `[suite, group, full source case name]`, with
`ensure_ascii=false`, comma/colon separators and one final LF. Their SHA-256 is
`1e88d600cf3cf13e29ed00b39a09137f6da18d6a7a24a6f011db4e446140b3ac`.

[source-sha256.json](source-sha256.json) records 33 inputs and four source trees
from the tested candidate. [source-comparison.json](source-comparison.json)
records the baseline/candidate differences. Later evidence-only changes must
preserve those input bytes and trees before execution evidence is reused.

## Limits

This uses controlled local child processes on the GitHub runner. It establishes
request serialization, native metadata admission in the fixture, typed timeout
behavior and actual public routing for the added case. The native client's own
`model/list` is preserved; it does not prove model entitlement. OpenAI's
[app-server guidance](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)
also distinguishes a returned catalog from successfully executing inference.

Seven changed OCaml files passed parsing; this is not local type checking.
Whitespace and the explicit changelog check passed. No local Dune build was run.
The large tool-dispatch suite whose API call was migrated was not selected for
execution. Full regression, real account/model access, installed runtime,
deployment, trusted non-author approval, integration and the full original
#27898 acceptance remain unverified. The issue stays open.
