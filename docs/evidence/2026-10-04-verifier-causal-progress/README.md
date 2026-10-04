# Verifier causal progress: focused execution

Measured 2026-10-04 KST. Candidate is PR #41004 head `1c053199bb5949039caadd0b7e8e196db6cfbd15` plus the two source changes in this follow-up: main #40995's public pick-list initialization and synchronization of the permanent-deferral notice test.

The user explicitly authorized these five local test targets as an exception to the repository's external-session no-local-Dune policy. Production configuration and runtime were not changed.

```sh
eval "$(opam env --switch=5.5.1 --set-switch)"
scripts/dune-local.sh build test/test_verifier_exact_lane.exe test/test_verification.exe test/test_goal_verification_agent.exe test/test_completion_repair_delivery.exe test/test_keeper_unified_verification_surface.exe
DUNE_SOURCEROOT="$PWD" _build/default/test/test_verifier_exact_lane.exe
DUNE_SOURCEROOT="$PWD" _build/default/test/test_verification.exe
DUNE_SOURCEROOT="$PWD" _build/default/test/test_goal_verification_agent.exe
DUNE_SOURCEROOT="$PWD" _build/default/test/test_completion_repair_delivery.exe
DUNE_SOURCEROOT="$PWD" _build/default/test/test_keeper_unified_verification_surface.exe
```

| Suite | Passed |
|---|---:|
| verifier_exact_lane | 21 |
| Verification | 97 |
| goal_verification_agent | 35 |
| Completion repair delivery | 27 |
| keeper_unified_verification_surface | 43 |
| Total | 223 |

The first three suites other than Goal/input ran directly without DUNE_SOURCEROOT; they initialize their registry themselves and passed. Goal and Keeper-input final runs used the explicit environment shown above.

Behavior exercised includes mixed provider rest, actual nested candidate identity, Goal recovery without resubmission, explicit same-request wake, drop invalidation, unchanged proof identity, approval queue failure/recovery, restart replay, enqueue-before-ack deduplication and single outcome rendering.

Initial failures are retained: wrapper rejected split opam5.5.1/5.5.0 environment; initial compile encountered inherited private pick-list record update, repaired with main commit0ec18301d0 (#40995); Goal's existing permanent-deferral test read Board before postcommit notice, repaired to await notice under its existing timeout; direct Keeper-input run lacked Dune prompt-root environment and failed18cases, then passed43with DUNE_SOURCEROOT. No production behavior claim or full-suite claim.

Raw local logs are retained under `/tmp/masc-verifier-causal-20261003/`; manifest.json records hashes and sizes. These local paths are not portable public artifacts. This report records executed focused results, not deployed recovery.
