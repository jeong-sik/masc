# Request-owned pricing and observed Agent accounting

Issue [#27898](https://github.com/jeong-sik/masc/issues/27898), bounded repair
[PR #47085](https://github.com/jeong-sik/masc/pull/47085), against
`a736fe763b15be2366c7c8d22f0b24796bdeedf6`.

The selected request owns its immutable model catalog and effective provider
permission through response annotation. Complete estimates against the typed,
exact model observation captured by the raw producer. Absent or unavailable
observations, missing rates and missing required cache prices remain unknown.
Explicit reported charges, including zero, survive. Agent only sums these
annotations and records gaps; it cannot query a catalog or estimate again.

The [decision](decision.md) records why the old accumulator API and its estimator
fixtures changed, including both independently found P2s. Terminal recovery
repricing was not established as a current defect.

## Executed and requested evidence

| Execution | Exact head | Actual result |
|---|---|---|
| [Baseline 41268718837](https://github.com/jeong-sik/masc/actions/runs/41268718837) | `d4d39a6c6f6d890b62b9e520a085b5891f7caa67` | FAILURE: 1 PASS, 9 FAIL; production identical to parent |
| [First candidate 41268950834](https://github.com/jeong-sik/masc/actions/runs/41268950834) | `5e6793b467853e5da9b2db155e710d70283b0f78` | FAILURE overall: 518 PASS across eight executed suites; provider-complete did not compile |
| [Amended candidate 41270706438](https://github.com/jeong-sik/masc/actions/runs/41270706438) | `fabbf6b8a6e04bc6f46e0a9245ec898ae621f2df` | FAILURE overall: 699 PASS, 2 FAIL; all nineteen pricing and six native HTTP pricing cases passed |
| [Fixture-corrected candidate 41271100485](https://github.com/jeong-sik/masc/actions/runs/41271100485) | `ab7634fe1fe3297a86b21784e8e96acc4b189e1a` | SUCCESS: actual 701 PASS, 0 FAIL across ten focused suites |

All use ref `fix/request-pricing-snapshot-20261101`. Counts from separate runs
are not added. The original ten-case baseline predates the deliberate
sum-only Agent contract; its fallback-estimation case is not the final
unknown-cost case. The final pricing module has nineteen cases, including
actual Agent calls, cache-price absence and all three typed observation states.
Six added loopback HTTP cases exercise direct sync/stream and factory-stream
paths, rotating the global catalog only after the server receives the request.

The two amended-candidate failures are existing Anthropic image fixtures that
expect five messages with the real caller input merged into a tool result.
The current serializer explicitly excludes `Conversation` origin from that
merge. The fixture-only successor preserves all image/tool payload checks and
asserts six exact roles plus the caller text in its separate final message.
The [parent HTTP execution](https://github.com/jeong-sik/masc/actions/runs/41271040500)
at `a736fe763b15be2366c7c8d22f0b24796bdeedf6` completed FAILURE, actual
99 PASS/2 FAIL: both same expected-five/received-six failures. The corrected
candidate's complete HTTP suite subsequently passed all 107 cases, including
the previously unreachable payload and caller-boundary assertions.

`manifest.json` binds checkout/ref/run metadata and separate raw/selected byte
hashes. Selected logs preserve actual cases and failure summaries; the original
logs remain under ignored `artifacts/issues-oldest-20261101/request-pricing/`.
`source-sha256.json` binds the reviewed implementation, fixtures, raw observation
boundary and workflow source to the executed corrected candidate. All 25
recorded input hashes match the retained source; this is not an exhaustive
dependency manifest or full regression run.

## Source and integration boundaries

Independent adversarial and response source review found no P0–P2 at
`ab7634fe1fe3297a86b21784e8e96acc4b189e1a`, base above, canonical full diff
`76890c2c99ed382a8d8a2694c756fa898bc9682c08f010769163375251bf9c0f`.
This is internal source review, not formal non-author GitHub approval.

Native Stack #47016 contains this PR at position seven. This evidence does
not establish whole-stack approval or integration, full regression, real
provider traffic, installed runtime, deployment or full issue acceptance.
The issue remains open.
