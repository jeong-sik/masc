# One catalog selection across a runtime batch

PR [#47305](https://github.com/jeong-sik/masc/pull/47305) gives a construction
one opaque owner. Its first HTTP binding selects admitted provider declarations
once; every later HTTP binding in that batch uses the same immutable selection.
A standalone construction starts a fresh owner. Native-only, empty, disabled
and unresolved Runtime_instance paths preserve their existing typed outcomes
without forcing unused HTTP declarations. Raw adapter callers provide an owner
and remain responsible for validation.

Both runs are workflow **Test**, ref `fix/runtime-batch-snapshot-20261101`,
explicit `minimal=true`, existing 600-second targeted-suite guard:

- baseline: [41316474568](https://github.com/jeong-sik/masc/actions/runs/41316474568),
  checkout `c2aa90ab8b376b7b8c3d418083e3a389b00af355`: **FAILURE, 7 PASS / 5 FAIL**.
- candidate: [41317548095](https://github.com/jeong-sik/masc/actions/runs/41317548095),
  checkout `995f8a4176ff8ec9f72a63437e2572600c2451f9`: **SUCCESS, 298 PASS / 0 FAIL**.

The same public twelve-case fixture materializes two separately declared HTTP
bindings. A real private owned regular File credential suspends the first
construction in Eio. Fork runs the child immediately and queues the parent
first; the parent replaces the private catalog before the constructor resumes
and the second binding starts. The pending promise proves the batch has not
returned, not whether the worker's physical read has finished. The inspected
constructor path establishes the first suspension. Both credentials, binding
order and first-binding policy checks pass before all five baseline failures
reach the second-binding capability, price, removal, absence or thinking check.
Fresh batches are constructed before those policy assertions; the successful
candidate also reaches their post-reload assertions. No sleep, retry, CLI,
network request or production test hook is used.

The twelve common cases have **seven successes maintained, five failures fixed,
zero regressions**: six batch-policy cases and six unused-catalog controls.
The other **286 candidate-only controls** are 13 account declarations, six
single-binding construction snapshots, 89 provider/auth-header cases and 178
configuration-validity cases. They are not baseline/candidate counterparts.
This fixture inspects selected policy/price and credential materialization;
it does not dispatch an HTTP request or admit the complete runtime startup.

`source-sha256.json` records 41 named inputs and four complete tree IDs at each
actual execution head. The twelve-case fixture, its stanza, Test/runner inputs
and test/dune are byte-identical. Core and config trees are identical; root
lib/test trees differ through four runtime files and seven mandatory-owner
caller updates. The full twelve-file source delta also includes the changelog.
Case identity uses source path, group, index and actual fixture SHA. The common
key digest is `aad0edd9bc457f3851cb0b03ef55e52e0a1c3da40422aeac044dfcb1ef1868a3` and all candidate keys hash
to `04a5afb1c0d4be024f9e86af744c07e27dd8181749b7786025398506a4a03d2b`; both hash compact UTF-8 JSON plus one LF.
`cases.tsv` expands all twelve common names from source; other display names
may be ellipsized and do not serve as identity.

Raw logs stay in ignored campaign artifacts. Retained text is an ANSI/BOM
normalized line-selected derivative preserving every case, checkout, target,
failure assertion and summary. Manifest digests distinguish raw and retained
bytes. Later evidence-only commits preserve the candidate's 41 named inputs
and four trees at this PR's own head; they do not execute those documentation
heads. The separate media repair above this PR is outside this execution.

Atomic publication of the two global catalog sources, account binding, native
implicit HOME and the remaining original #27898 hard cut remain open. Full
regression, installed runtime, real provider/account, OS restart and whole-stack
integration are unverified. No local build/typecheck ran. Source/evidence review
is separate from trusted non-author GitHub approval and merge. No issue is closed.
