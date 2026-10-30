# Scheduled-job repair validation

These captures supplement the original audit; they do not overwrite its F1/F6
counterexamples. [Focused CI and native artifact evidence](README-core.md) records
F4's 115 passing cases, F1's 76 explicit passing cases plus the queue executable,
and the macOS operator build and portable runtime package. The native workflow
definition is `117dc31e1ca8f71f47bbbe91fa2adab5befb5761`; its actual product source
is `94b2df25abcdfe20c658322f4156ad63f5546c34`. The locally verified server SHA-256
is `a0bd5c3903ef6425024e47b9dc92a7615f4efbb941357ea36e74ac5a18284668`.
No production executable was replaced.

`manifest.json` records a snapshot of the retained files, rather than enforcing
future edits. Its `captured_at` identifies the original bundle capture; each
subsequent change to a retained file requires refreshing its `files` hash. The
individual run timestamps and original digests remain historical records.

| Isolated run | Actual observations | Limits |
|---|---|---|
| [DeepSeek busy](real-busy-deepseek-fixed-1/README.md) | First checkpoint has no premature ACK; successor completes; first source is admitted again and completes; both exact notes exist once | Original observer remains 9 PASS/1 FAIL, exit 1: it missed the short HTTP overlap window. The original durable ledger independently establishes the overlap. Both notes were written during turn 2, before first-source readmission. Producer exit code unavailable. |
| [GLM busy](real-busy-glm-fixed-1/README.md) | Checkpoint → second note/completion/ACK → first readmission → first note/completion/ACK; 11 observer checks PASS; server exit 0 | One owned Keeper and two internal note effects. No account/provider failover or crash recovery. |
| [DeepSeek after first effect](real-after-effect-deepseek-fixed-1/README.md) | First note → successor arrival while first turn remains unfinished → normal first completion → second completion; each note once; 11 checks PASS; server exit 0 | No checkpoint/readmission occurred. An attempted `Execute` was refused before any observed shim receipt; this is not an all-tools-success or guest-execution result. |
| [Second after-effect attempt](real-after-effect-deepseek-fixed-2/README.md) | Same two exact effects and terminal readback, 11 checks PASS, server exit 0, successor delay reduced to the tool's legal one-second minimum | Still normal sequential completion, with no checkpoint/readmission. Root inspected this capture; the independent reports cover the other three runs. |

The first three reports directly compare original raw ledger rows, tool receipts,
note timestamps and exact schedule-instance/occurrence identities. Repeated event
ids in reaction history are not deduplicated when reconstructing resumed attempts.
API reaction summaries alone can retain the earlier checkpoint finish timestamp.
This does not establish arbitrary-effect exactly-once execution or the general
durable causal join between a request and every possible output.

`probes/busy-notes-v3.py` is the measured v3 observer source. The two adjacent
patches reconstruct v2 and v4 from that exact file; their full source digests are
in [manifest.json](manifest.json). v3 adds an exact durable-history overlap witness
when HTTP sampling misses the transition and stops a terminal idle producer before
reporting an unmet fixture precondition. v4 changes only the successor delay to
the legal minimum. Original observers, decisions and raw hashes remain unchanged.
Only owned synthetic workspaces were used; credential values, authorization
headers, live turn-control tokens and model thinking are omitted.

The historical focused CI failure is retained: **Test
[40341860767](https://github.com/jeong-sik/masc/actions/runs/40341860767)**,
head `b5c9762b27845918eba2acb804434a0da435cc78`, ref
`fix/schedule-work-continuation-20261026`, conclusion **failure**. The corrected
connector suite passes all 32 cases. Owner executes 106 cases, with 103 passing
and three scheduled-handoff failures (`operation did not become terminal`).
The [selected failure receipt](f6-ci-failure/selection.json) preserves exact source
log lines and original hashes; the raw archive remains under the ignored local
capture directory. The fixtures omitted the production runner's exact checkpoint
resume step and attempted success while semantic execution was suspended.

The corrected fixture then passed **Test
[40348100243](https://github.com/jeong-sik/masc/actions/runs/40348100243)** at head
`ccb0007e95ead82676a58d0dcc17d740dfe94f30`, ref
`fix/schedule-work-continuation-20261026`, conclusion **success**:
[106 Owner cases PASS, FAIL/SKIP 0](f6-owner-ci/README.md), including all three
previously failing cases. This run selected only the Owner alias; it was not a
full regression run. That source precedes the subsequent rebase onto main
and is not an execution result for `6dedd652df1273c9476a04643b445601e30181ad`.
The native product source and these real-provider runs are also not current-head
CI or installed-runtime evidence. After-effect checkpoint/restart,
cancel/replacement during continuation, F2/F5 recovery, external delivery, real
Lane workers and TUI behavior remain outside these results.
