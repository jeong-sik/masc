# Provider policy presence is not a thinking override

Focused native run [40078581651](https://github.com/jeong-sik/masc/actions/runs/40078581651)
on `7501aec032012869d8b979e0d14e1a9a9464ace7` failed the existing declared-provider
capability test: its declared-native case expected a serialized `thinking`
field but received no field. This is a test expectation mismatch, not an
observed change to the request serializer.

The fixture constructs `claude-fable-5` without `enable_thinking`. Its native
catalog row declares an `always_adaptive` policy. A declared price and policy
exist, but neither implies an explicit request override: unset thinking emits
no control field, as does this always-adaptive policy when explicitly enabled.
The proxy has no declared price or policy and also emits no control field.

The repaired test keeps the price and policy authority assertions and expects
the unset thinking override to remain absent. No runtime serializer, catalog,
configuration or reported-model capture behavior changes.

## Evidence boundary

`observations.json` records byte-identical `Provider_config` and model-catalog
files between base `43162710e28f61375ece2d6497de9892705ef691` and the failed
candidate. The original test function and the actual thinking projection are
also byte-identical. The backend's campaign change only captures raw response
model evidence in its response parser.

Reproduce the bounded source probe with a new output directory:

```sh
python3 docs/evidence/2026-10-24-provider-policy-test/verify_policy.py \
  --repo "$PWD" --out /tmp/masc-provider-policy-check-new-directory
```

The probe compiles the actual thinking projection from both exact commits,
using its actual policy variant declaration and an explicit typed input port
for the single config field it reads. Four checks pass on each source: unset
native, enabled always-adaptive native, unset unknown proxy, and a positive
adaptive control. This proves the unchanged projection; it does not execute
the complete request builder or a baseline native test binary.

The repaired test source parses and `git diff --check` passes. No local Dune
command or post-repair native test execution was performed. The parent owns
the next exact-candidate native check; the earlier failed run remains failed.
