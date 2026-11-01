# Collected terminal response recovery

This repair for [#27890](https://github.com/jeong-sik/masc/issues/27890) is
[PR #47059](https://github.com/jeong-sik/masc/pull/47059), the fifth layer of Native
Stack #47016. The full single-writer hard cut remains open.

The provider response and After_assistant_collected checkpoint can be persisted
while the provider and owning turn are still open. Recovery previously required
a ToolUse checkpoint even for a final text response. Three new public-entry
regressions reached that refusal on otherwise valid restored state.

Recovery now validates the restored collected counter against the owning
journal turn, converts the restored assistant blocks to wire form, checks exact
response content, and refuses any persisted Tool invocation on this terminal
path. Both open and successfully closed provider boundaries obtain their turn
ordinal from the journal instead of deriving it from the mutable checkpoint
counter. The exact persisted response, including identity and usage, is returned
without a new provider call, duplicate usage charge or AfterTurn callback.

The open-provider path executes the shared output continuation under its exact
provider authority. It rejects Unknown, UnmatchedToolCalls and empty StopToolUse
and propagates OnStop exceptions and illegal decisions. Independent review
found both missing checks in the initial uncommitted repair; both were corrected
before the tested source commit.

OnStop is a synchronous lifecycle callback. This recovery contract explicitly
allows it to repeat when interruption occurs before successful provider close.
Callbacks must tolerate replay. A successful provider close proves output
finished, so recovery reuses that outcome without calling the restored hook.
The tests include a callback already called before interruption and a closed
provider whose restored callback would fail if invoked. This does not claim
exactly-once callbacks or convert an unknown Tool effect to a successful result.
The distinction between recorded completion and repeatable callback execution
was also checked against the primary [Temporal activity documentation](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/activities/activity-definition.mdx);
the implementation follows the local Agent/Hook contract.

## Executions

All rows are the **Test** workflow on ref
`fix/terminal-resume-frontier-20261101`. Actual suite cases are counted once;
decorative failure-detail repeats and assertion lines are not extra cases.

| Run | Executed head | Conclusion and actual result |
| --- | --- | --- |
| [41263934742](https://github.com/jeong-sik/masc/actions/runs/41263934742) | 4e6ed25221ec8068ca10df7533b613d3b5cc2ace | Failure before tests: the new fixture called a nonexistent Agent.resume_error_to_string. No functional red proof. |
| [41264217427](https://github.com/jeong-sik/masc/actions/runs/41264217427) | fcf39f9b0aa68995d1673505a061b22241644901 | Failure: Pipeline **87 PASS / 3 FAIL**. Regular, streaming and Advanced cases all reached the existing open-provider/no-ToolUse refusal. Production sources were unchanged from the parent. |
| [41264800274](https://github.com/jeong-sik/masc/actions/runs/41264800274) | ae3c58687d560382a2facc13930a86e841519ee4 | Success: **123 actual PASS**: Pipeline 101, Pipeline_illegal_hook 1, Execution journal 21. |

The final run requested only
`packages/agent_core/test/test_pipeline,packages/agent_core/test/test_pipeline_illegal_hook,packages/agent_core/test/test_execution_journal`
with `minimal=true`. It is not full regression. The earlier stack layer's 158-case
run is separate evidence and is not added to these 123 cases.

The final Pipeline suite adds 14 cases over the parent's 87: three public
entrypoints, three invalid stop reasons, pending/raising/illegal/repeated/closed
OnStop, and counter/content/invocation refusal. Failed recovery emits no
successful canonical TurnCompleted. Accepted recovery emits one live completion
with the exact envelope available through public projection catch-up.

Fixtures commit the interrupted topology, reopen the public projection, decode
its retained checkpoint and restore a fresh Agent through Agent.resume. They
run within one process. This is persisted interruption/reopen evidence, not an
OS crash or process restart. Real provider HTTP, installed runtime, deployment
and Dashboard behavior were not exercised. No local Dune build was run.
Syntax-only parsing of the changed OCaml files passed with warning 50 disabled;
the stricter probe reported existing ambiguous/unattached documentation in
Agent.mli and Pipeline.ml and was not a typecheck.

## Provenance and remaining scope

[manifest.json](manifest.json) records the exact runs, source hashes, full raw
job-log hashes and separate selected-text hashes. Complete logs remain in
ignored artifacts/issues-oldest-20261101/terminal-resume-27890. Retained text
strips ANSI, selects checkout/suite/error/assertion/summary lines, trims trailing
whitespace per line and keeps one final newline. Derivative hashes do not replace
raw capture hashes. Evidence/changelog-only commits do not become tested heads.

Independent source review of base
`ee98517f7125e764b711151cf049041bdec33116` to candidate
`ae3c58687d560382a2facc13930a86e841519ee4` found no remaining P0-P2. Its canonical
Git-object diff identity is
`c34884a705a2afb4d65fef0af65798bb76a350d54934eca0ea4b5c1395f565b2`.
That source review is separate from execution and from a formal non-author
GitHub approval. Final evidence review binds its own current head and full diff.

Required caller checkpoint sinks retain their current ownership and failures;
this change does not install automatic checkpoint restoration or duplicate
caller checkpoints into the Core journal. Full MASC checkpoint/Input/Native/Owner
authority, remaining lifecycle/Raw_trace/Custom telemetry projections, explicit
finite-run retention and complete process-restart proof remain issue scope.

## Subsequent stop-reason recovery repair

The executions above belong to their recorded historical source. A later source
change at `e95d3c79f9e3f846cc174bbfa5e1a1f465346785` was independently rejected
for two P2 defects: MaxTokens with ToolUse entered a validator requiring
StopToolUse, and successfully closed terminal responses were still classified
by message shape. Neither the old source-preservation receipt nor the external
commit message establishes execution of this follow-up.

Thirteen additional cases compare fresh output with persisted active,
provider-closed and turn-closed recovery, including registered ToolUse under
MaxTokens, Refusal and injected EndTurn, plus malformed-stop controls. They
check exact recovery, zero effects/redispatch/AfterTurn, pending-only OnStop,
unchanged usage/counter and no canonical tool observations. New execution
receipts will retain their own heads and outcomes; no completed result is
claimed here. Full regression and issue acceptance remain unverified.
