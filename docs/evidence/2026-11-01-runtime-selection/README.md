# Materialized MASC runtime policy

Bounded repair [#47111](https://github.com/jeong-sik/masc/pull/47111) for
[#27898](https://github.com/jeong-sik/masc/issues/27898), against
`29cdfab14394dd3dfb762eb836fa1873a64be64b`.

`Runtime_adapter.binding_to_provider_config` previously returned an unfrozen
config. `Runtime_instance` retained it, but context and price queries could
resolve that config against a later global catalog. The successful
materialization now passes through the existing opaque
`Provider_config.freeze_for_request` boundary. Existing runtimes retain their
selected model policy and price source, including a captured absence; newly
materialized runtimes observe the replacement catalog.

No new cache, field, knob or retry policy is introduced. Explicit context,
capability and thinking overrides retain precedence. Materialized secrets and
refreshable credential sources are preserved. Official-client execution takes
its existing separate branch.

## Executions

| Test execution | Exact head | Result |
|---|---|---|
| [Baseline 41271591841](https://github.com/jeong-sik/masc/actions/runs/41271591841) | `469c440fdb4ddfe046a592a49ff86f14f7264db7` | FAILURE: actual 174 PASS/4 FAIL |
| [Candidate 41271778781](https://github.com/jeong-sik/masc/actions/runs/41271778781) | `1b4b399005ada1427cdf1bfe27a8087ed17f2b35` | SUCCESS: actual 270 PASS/0 FAIL across three focused suites |

Both use ref `fix/runtime-selection-snapshot-20261101`. Baseline production is
identical to the parent; only four public `Runtime_instance.of_binding`
consumer cases were added. The old context changes from 4096 to 8192; an absent
context becomes 8192; an input price of 1 becomes 10; an absent price becomes 10.
Each case fails at its old-selection assertion, so baseline does not establish
its later fresh-selection assertion. No old assertions were replaced.

The context-absence case tests a materialized value before loader validation.
It does not show that the runtime loader admits an unknown-context runtime.
The candidate passed runtime configuration178, provider/auth headers73 and
request pricing19. All four new cases passed their retained-selection and
fresh-selection assertions; their source is unchanged from baseline. This is
not a full regression run, and separate runs' counts are not added.

`manifest.json` records exact execution/ref/status and independent raw/selected
byte digests. Original logs are retained under ignored
`artifacts/issues-oldest-20261101/runtime-selection/`. Eighteen recorded source,
fixture, config and workflow inputs plus the fixture-tree Git identity are in
`source-sha256.json`; this is not an exhaustive build dependency manifest.

## Source and remaining scope

Independent adversarial and response source review at candidate
`1b4b399005ada1427cdf1bfe27a8087ed17f2b35`, base above, canonical full diff
`b0df37e8dfcf617d4a7d4f1ea8ade584bebe8a4fe7f7792de6be0bac721e789b`
found no P0–P2. This does not certify a future evidence head or establish formal
non-author GitHub approval.

This freezes the fully built config. It does not combine all construction-time
catalog projections into one admission transaction. The existing dispatch
credential-requirement lookup still reads the live registry; official-client
reasoning policy is also outside this repair. Whole-stack integration,
installed runtime, real provider traffic, deployment and full issue acceptance
remain separate. The issue stays open.
