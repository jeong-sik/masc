# Stagehand real provider probe — 2026-09-27

**Result: failed. The real-model merge condition for #38739 is not satisfied.**

This execution used the CI-built macOS arm64 binary from source `c54123bba424c016a12ed0e023434586704d1b89` and a new private workspace seeded from that commit. It did not change the running MASC configuration, start a browser, or invoke a live Keeper. The CI artifact build and both host offline controls passed; provider invocations exited with status 1 after 32.572 seconds.

## Actual results

| Route | Request | Valid / invocations | Shape valid |
|---|---|---:|---:|
| primary_only | extract | 0 / 3 | 0 |
| primary_only | progress | 0 / 3 | 0 |
| primary_only | act | 3 / 3 | 3 |
| fallback_only | extract | 0 / 3 | 0 |
| fallback_only | progress | 0 / 3 | 0 |
| fallback_only | act | 0 / 3 | 0 |
| synthetic_primary_503_then_real_fallback | extract | 0 / 3 | 0 |
| synthetic_primary_503_then_real_fallback | progress | 0 / 3 | 0 |
| synthetic_primary_503_then_real_fallback | act | 0 / 3 | 0 |

Each attempt is one `Browser_stagehand_model.create` invocation, not a count of underlying provider HTTP dispatches. The 24 failed invocations returned RPC refusal `-32000`; the aggregate envelope alone does not identify the provider cause. The primary Act response passed both shape and semantic validation in all three invocations.

All nine injected-primary trials observed the credential-free loopback HTTP 503 request. None produced a valid fallback response, so this proves injected primary failure was reached but does not prove successful provider failover.

## Reproduction and evidence

- Build artifact: https://github.com/jeong-sik/masc/actions/runs/36262869811
- Binary SHA-256: `fd37c32272c3fca4b88697cc81949d770330db967748a0214477cd348a109cd1`
- Fixture and artifact file hashes: `artifact-manifest.json`.
- Secret-free per-invocation observations and summaries: `results.jsonl`.
- Host execution identity, duration and exit code: `execution.json`.

Use the explicit isolated configuration/base-path command documented by `bin/stagehand_model_probe.ml` and its artifact README with `--repetitions 3 --injection-timeout-s 30`. The latter is the local injected transport bound; the real providers retain their configured deadlines. Credentials remain in the host environment. Private stdout/stderr, provider response text, runtime files and environment values are intentionally excluded from this evidence.

These recorded fixture calls cover Extract, Progress and Act through the model adapter. They do not establish arbitrary schema support, browser interaction, deployed-server identity or long-running Keeper continuity.
