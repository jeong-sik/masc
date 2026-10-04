# Wire preflight without unreachable request retention

Baseline #40991 `bee7a1045803579c4ec6fbb6a73b5c33700eed2d`, direct parent `b714e11dbd29fea05e87fda27e0e138fdc2c40fa`, Native Stack #40961 position5/7. Current comment4179430234 reproduced in the existing actual stdio wire-frame test.

The Too_small boundary sends three sequential sampling requests using the actual SDK transport. The old product completes each bounded error frame and makes no model call but leaves three request blobs without request journals. The regression requires no unreachable blob and no journal. The fix encodes bounded immutable request bytes, computes their content-addressed reference without publication, performs the existing complete JSON-RPC error-frame preflight including actual ID and newline, then durably writes the same request bytes and Pending journal before invoking the model. Successful and exact-boundary error receipts remain unchanged. Request and outcome persistence stay mandatory.

The existing wire case retains both escaped Unicode/string and long numeric IDs, exact success/error boundaries and byte overflow assertions. It now additionally reads the request blob inside the host callback to prove every admitted model call still has a durable request. Three rejected calls are checked per ID. No new callback/API or magic headroom is introduced; the query/aggregate budget path is unchanged.

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_lane_addon_worker.exe
(cd test && ../_build/default/test/test_lane_addon_worker.exe test lifecycle 20)
(cd test && ../_build/default/test/test_lane_addon_worker.exe)
```

Meaningful RED: lifecycle20 failed with expected0/actual3 unreachable blobs. Final focused build passed, then the complete small worker executable passed **42 cases in7.165s**. This is this candidate’s worker/native/actual stdio fixture result, not an execution of descendants, a live provider, full repository suite, hosted CI or TerminalBench. All four raw logs are copied byte-for-byte and final source/binary/log hashes are recorded in checks.json.
