# Independent completion evidence at final source projection

PR [#47152](https://github.com/jeong-sik/masc/pull/47152) fixes the remaining
completion-evidence failure observed in #47146. The completion-review fast path
returned its supplied messages, then the final shared source projection added
a Keeper unread observation. The final projection now consumes the existing
typed input source. Explicit custom views and typed errors apply to both sources;
only Keeper history receives its frozen unread observation.

## Actual executions

Both are workflow **Test**, ref
`fix/completion-evidence-projection-20261101`, with `minimal=true` and explicit
targets:

| Role | Run | Actual checkout head | Selected targets | Actual conclusion |
| --- | --- | --- | --- | --- |
| Parent-production baseline | [41284905852](https://github.com/jeong-sik/masc/actions/runs/41284905852) | `95fc86deba4db4c1bc2d17f5d3c3253f7626475a` | `test_keeper_codex_completion_evidence` | FAILURE: 1 PASS / 3 FAIL |
| Candidate | [41285063692](https://github.com/jeong-sik/masc/actions/runs/41285063692) | `a636084c8a77b989ba7b6d115965fbd935bf7207` | `test_keeper_codex_completion_evidence,test_keeper_librarian_request_unread` | SUCCESS: 11 PASS / 0 FAIL |

The baseline's `lib/`, `packages/agent_core/` and `config/` trees equal parent
`737ce742f55b8c125ef502ad2d4ac3048c279dd1`. The focused Codex fixture and its Dune
target are byte-identical across the pair. The whole test trees differ by the
new required input-source argument in the separate unread consumer test.

All four common completion cases keep the same order. Three FAIL become PASS,
one refusal control remains PASS, and no PASS regresses. The candidate's other
seven PASS are shared Keeper unread projection checks; they did not run on the
baseline. The selected completion group took 4.056 seconds on the baseline and
4.093 seconds on the candidate. The enclosing alias also compiled its executable
and took 444/531 seconds respectively; those totals are not behavior latency.

The existing exact-evidence assertion also checks that tiny capacity does not
cut independent completion evidence and that Keeper continuity readers are not
consulted. Its body is unchanged in parent, baseline and candidate: 1,210 bytes,
SHA-256 `10c7756ef9fa7c5546bd97a07fc412e91934a9759a767ab9df2494ceb064bb25`.
It was moved into the focused group without weakening or skipping it.

Two added cases drive the real adapter and child protocol with original evidence
and with an explicit custom source view. Both first verify the exact injected
user contents; their baseline failures then directly observe a fabricated
Librarian unread note in native `thread/start.developerInstructions`. Both
candidate requests omit that note. The custom view runs once. The fourth case
confirms that an explicit typed projection refusal propagates and sends no
provider request; it passes in both executions.

The seven candidate unread checks cover frozen source/absorption order,
snapshot-versus-Memory uncertainty, canonical rendering, the capacity floor,
held/omitted context, custom-view replacement attempts, and known-empty versus
unavailable observations. These are shared projection checks, not seven live
native client sessions.

## Provenance

[manifest.json](manifest.json) records workflow/ref/head, actual checkout,
per-target counts and separate raw/selected byte counts and SHA-256 digests.
[baseline.txt](baseline.txt) and [candidate.txt](candidate.txt) retain every
actual timestamped case row, failure assertion, expected/received values,
selected target, checkout receipt and runner summary. They are ANSI/BOM-normalized
derivatives. Other groups' SKIP rows, decorative repetitions and routine build
output are omitted; skipped groups are not counted as PASS.

Raw logs and capture metadata remain in ignored
`artifacts/issues-oldest-20261101/completion-evidence-projection/`.
[case-comparison.json](case-comparison.json) maps the actual group/index to the
full literal case name in each historical source, rather than using ellipsized
display names. Its ordered keys are compact UTF-8 JSON arrays of
`[suite, group, full name]`, `ensure_ascii=false`, comma/colon separators and one
trailing LF: SHA-256
`f08b4b0bce278ae9871d2a7c4960eb02878ea782fd0732ec0411a63ca56b4973`.

[source-sha256.json](source-sha256.json) records 20 inputs and four source trees
at the tested candidate. [source-comparison.json](source-comparison.json)
records baseline differences, identical focused fixtures and the preserved
original assertion. Evidence-only descendants must preserve those inputs and
trees before reusing this execution.

## Limits

Only the four selected completion cases ran from the Codex context executable;
its other groups were skipped. The earlier 40/41-case executions and their
failed workflow conclusions remain unchanged. The new 11 PASS execution is not
a replay of that whole context suite or a full regression.

The native writer measurements use a controlled Codex child process. Claude's
direct caller and the shared Muse/Antigravity caller are verified from source;
their live native writers were not executed here. Six changed OCaml files passed
parsing, whitespace and the explicit changelog check passed, and no local Dune
build/typecheck was run. Real account/model access, installed runtime, OS restart,
integration, deployment, formal non-author approval and the original complete
catalog or journal hard-cut acceptance are not established. No issue is closed.
