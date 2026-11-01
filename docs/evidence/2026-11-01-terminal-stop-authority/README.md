# Persisted stop reason owns terminal recovery

The executions below are historical evidence for `c3d7d202c2abad5a9b5fa173757fe621fcc797e0`
and its source-identical `665fe430a9b189702a18c42713cad398adaac57f` publication.
They do not execute the later canonical-response persistence repair or its
expanded palette-change fixture. That follow-up moves the response snapshot
after admission and before AfterTurn/checkpoint publication; recovery uses
the exact stored canonical response instead of the resumed agent's tools.
The intermediate `356a1e02ce3637668c357cf4467d738243c51fe9` commit is preserved
in history. Its current-palette re-admission and invalid `-1` fixture suffix
were found by two independent source reviews; no execution at that head is
claimed here. The follow-up uses the valid numeric suffix and adds actual
durable producer checks plus tool-removal/AfterTurn-addition recovery cases.

PR [#47059](https://github.com/jeong-sik/masc/pull/47059) now uses the persisted
stop reason at both active and successfully settled recovery boundaries.
MaxTokens and other terminal reasons preserve their exact response, including
any admitted ToolUse content, without authorizing tool effects. StopToolUse
keeps strict ToolUse/result/invocation validation. Unknown and unmatched stops
remain rejected. An open provider runs pending output/OnStop; a successfully
closed provider replays its decision without repeating the hook.

The earlier [terminal-resume evidence](../2026-11-01-terminal-resume/README.md)
remains bound to its historical source. This follow-up preserves the intervening
`e95d3c79f9e3f846cc174bbfa5e1a1f465346785` commit in history and repairs two P2
cases it did not cover: MaxTokens entering a tool validator that requires
StopToolUse, and settled terminal ToolUse content being mistaken for executed
tool work that must have ToolResults.

## Actual executions

Every execution is workflow **Test**, ref
`fix/terminal-resume-frontier-20261101`, `minimal=true`, targeting exactly
`packages/agent_core/test/test_pipeline,packages/agent_core/test/test_execution_journal`.
The existing per-suite CI guard is 600 seconds.

| Role | Run | Actual checkout | Actual conclusion |
| --- | --- | --- | --- |
| Invalid fixture baseline | [41288965057](https://github.com/jeong-sik/masc/actions/runs/41288965057) | `4f88413fdbd8eb4d27bcb5c134828becdf00720d` | FAILURE: Pipeline compilation failed, zero Pipeline cases; journal 21 PASS |
| Invalid fixture candidate | [41289637453](https://github.com/jeong-sik/masc/actions/runs/41289637453) | `68119836b420bee9d2b26be19cc913f08c2c41e0` | FAILURE: same fixture compilation error, zero Pipeline cases; journal 21 PASS |
| Corrected fixture baseline | [41291035705](https://github.com/jeong-sik/masc/actions/runs/41291035705) | `e185f43bf978cc4922584754f9e3e398ec2cff57` | FAILURE: 126 PASS / 9 FAIL |
| Corrected fixture candidate | [41291435494](https://github.com/jeong-sik/masc/actions/runs/41291435494) | `c3d7d202c2abad5a9b5fa173757fe621fcc797e0` | SUCCESS: 135 PASS / 0 FAIL |

The first fixture passed a public abstract Agent.t to an internal Pipeline
helper requiring Internal_agent.t. These two failed runs are retained and do
not establish any Pipeline behavior. The corrected fixture calls public
`Agent.run` for its fresh control and verifies exactly one provider call.

The corrected pair has byte-identical complete test trees. Its only two-file
delta is `pipeline_execution_resume.ml/.mli`. Baseline production trees equal
`e95`; candidate production trees equal `681`. The valid baseline has Pipeline
105 PASS / 9 FAIL and journal 21 PASS. The candidate has Pipeline 114 PASS and
journal 21 PASS. All 135 common cases remain identified: 126 PASS stay PASS,
nine FAIL become PASS, and no PASS regresses. Passing journal counts from
other executions are not added to the candidate's 135.

Pipeline behavior took 2.073/2.809 seconds on the valid pair; journal behavior
took 0.296/0.288 seconds. These are the test runner summaries, not cold build
time, live model latency or fleet performance.

## What the new cases establish

Thirteen new cases register a real effect-counting tool and first verify the
fresh public Agent behavior. The response retains that admitted ToolUse,
preventing an unavailable tool or content filtering from producing a false
zero-effect result. MaxTokens, Refusal and deliberately injected EndTurn each
cover active, provider-closed/turn-open and provider-and-turn-closed windows.
Streaming and Advanced API controls cover active MaxTokens; unknown and
unmatched-stop controls remain rejected with ToolUse present. Existing wire
normalization is unchanged; injected EndTurn is a typed API-boundary case.

Accepted terminal cases check the exact persisted response; malformed-stop
controls check typed rejection. All passing cases check zero tool effects and
provider redispatch, no repeated AfterTurn, OnStop only for pending accepted
output, unchanged collected usage/counter, zero canonical tool observations
and the root terminal outcome. Advanced also checks the nonzero
provider turn ordinal. Failed baseline recovery cases can stop at their first
result assertion; they do not establish that all later assertions ran. The
new group has four maintained PASS and nine FAIL→PASS.

## Provenance

[manifest.json](manifest.json) records all four run/ref/head/checkout receipts,
actual conclusions, per-suite counts, separate raw/retained sizes and SHA-256
digests. [invalid-baseline.txt](invalid-baseline.txt),
[invalid-candidate.txt](invalid-candidate.txt), [baseline.txt](baseline.txt) and
[candidate.txt](candidate.txt) retain every actual timestamped case row,
selected target, checkout, summary and captured failure assertion. These are
ANSI/BOM-normalized derivatives. Routine build output is omitted; every
completed row remains counted exactly once.
[invalid-fixture-diagnostics.txt](invalid-fixture-diagnostics.txt) additionally
retains the exact normalized compiler location/type context for each invalid
fixture run. It has its own derivation and digest. Raw logs remain in ignored
`artifacts/issues-oldest-20261101/terminal-remote-advance/`.

[case-comparison.json](case-comparison.json) seals all common identities with
the byte-identical test source SHA-256 plus actual suite/group/index; ellipsized
display names are not identities. It also supplies the full literal names of
all thirteen new cases. Ordered keys are compact UTF-8 JSON
`[test source path, group, index, source SHA256]` arrays, `ensure_ascii=false`,
comma/colon separators and one LF: SHA-256 `f13407fc77ba93feb2ace9592c1a5f61a31c6d75a505680be221c4999f03f6b7`.

[source-comparison.json](source-comparison.json) records the exact baseline/
candidate production references, two-file delta and identical test trees.
[source-sha256.json](source-sha256.json) records 19 inputs and four source trees
at the actual successful candidate. Evidence-only descendants must preserve
all of them before carrying that execution; their final SHA is not the CI
checkout. The old initial source-preservation receipt is not substituted for
this comparison.

## Limits

These are focused Pipeline and journal tests with a controlled injected
provider and real public Agent APIs. Persisted recovery is reconstructed in
one process; an OS restart, real provider/account, installed runtime, full
repository regression, whole-stack integration and deployment are unverified.
No local Dune build/typecheck ran. The latest observed prior scheduled Test
attempt is recorded separately in the manifest. Formal non-author approval
and #27890's entire single-writer journal hard-cut acceptance remain separate.
No issue is closed.
