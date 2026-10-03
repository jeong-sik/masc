# Remaining runtime-lane editor scenarios

Parent #41043 repaired the first replacement/promotion scenario of the release target. Executing its whole existing target exposed subsequent stale labels and fixture waits. This child repairs only the existing Python target; product source and timeout bounds are unchanged.

- The exact-lane second picker renders model-b default, while conversation pickers retain runtime ID labels. The changed expectation preserves the exact two append POSTs and dropped-slot preservation assertions.
- CLI reorder/append and empty-group/curator append waits now consume terminal output with the existing fixture-state helper. The same five-second deadline applies. The old sleep-only CLI wait failed with no request and incomplete output; the changed wait passed the exact reorder/append and declared-order assertions.
- Curator/provider Esc checks wait for the actual cleared-filter count, then confirm the picker remains visible. The unchanged modal title need not redraw. Provider-slot selection waits for its resolved model/effort label and still checks the exact provider TOML table with no routing write.

## Execution

The complete official Python entrypoint ran through all eleven scenarios and exited0 in about38seconds. The accompanying manifest, per-scenario results, log, requests and raw artifact hashes identify the run. Every original mutation, refusal, config navigation and slot-order assertion remains in place.

The executable is the existing macOS ARM64 artifact from RC37137607438, embedded commitfd7e6c37e006af09b1dba65fb2b3b55249104c7f, binary SHA256f3531778d03b6b2bfd68ae86ba47507cb653bcffd62cd543b2720c4e918b882d. The executed script SHA256 is7639284e242e872194b233d205d67479253fd9f305e97159e257fafdcd83a52a; source, harness and binary hashes stayed unchanged throughout execution. The external runner wraps scenario execution only to record terminal output, PID and requests, then uses runpy on the unmodified official entrypoint. It rethrows failures and reports the process exit separately.

Earlier failed diagnostic captures remain in /tmp/masc-runtime-lane-suite-feeefca-20261004, /tmp/masc-runtime-lane-followthrough-corrected-20261004, /tmp/masc-runtime-lane-followthrough-drain-20261004, /tmp/masc-runtime-lane-census-20261004, and /tmp/masc-runtime-lane-final-target-20261004. An initial wrong-occurrence patch was caught by independent review and restored before publication; its run is excluded from product evidence.

## Limits

This proves the changed fixture against that existing native binary, not a rebuilt child head, the latest e4afdce8 release binary, Linux execution or a successful Full RC. Python AST, changed-source whitespace and changelog checks passed. Earlier subagent source reviews covered individual steps; the last complete-diff review is requested independently because those agents hit their usage limit. Final candidate assembly and same-head full verification remain under #41029.
