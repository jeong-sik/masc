# Earlier cooling retry must advance its observation wake

Measured source base: `1fac40687d05baa94e453ff8dbfa4452daa4e18e` (#45655).

The Owner tracked only whether a cooling-retry wake was armed. A new retry whose durable deadline was earlier reused the old later sleep. The store correctly made the original request eligible at its deadline, but automatic observation/claim started late.

The candidate retains the current reservation's actual Eio-clock wake instant and a supersession promise. A strictly earlier wake replaces the pending reservation and cancels its old sleeper through `Fiber.first`. Later requests preserve the earlier wake. A private reservation's physical identity prevents an old due/failure cleanup from clearing or notifying for its replacement. The observation interval, durable `not_before`, exact dependency witness, queue order and transient retry fuse remain unchanged. Waking observes eligibility; the timer grants no execution authority.

## Reproduction and measured result

The identical native Owner test runner is linked to original and candidate production source. It creates two original operations through Owner admission/claim/defer APIs while the executor dependency is not ready, then makes that dependency ready and advances the mock clock to its next scheduled wake. The executor calls `claim` and `resume_direct_runtime_retry` before recording the exact original operation ID and clock value. Thus the receipt observes original work starting, rather than merely a timer callback or a queue projection.

The configured observation interval in this capture is 0.5. The earlier retry deadline is one quarter of that interval (0.125), while the later one is twice it (1.0). Those values describe the controlled fixture and do not add a production threshold.

| Scenario | Expected clock | Original actual claim/resume | Candidate actual claim/resume |
|---|---:|---:|---:|
| Later retry admitted first, earlier retry added second | 0.125 | 0.500 (FAIL) | 0.125 (PASS) |
| Earlier retry admitted first, later retry added second | 0.125 | 0.125 (PASS) | 0.125 (PASS) |

The unnecessary wait is 0.375 controlled-clock seconds in the first case. This is not a wall-clock, provider, TUI or production-latency improvement percentage. The real clock's 2-second test watchdog diagnoses failure to receive the executor receipt; it does not drive the ordering assertion. The mock clock advances once to the actual scheduled event, without yield-count or wall-clock inference.

Before production edits, source, runner, stanza and executable hashes were recorded. The original executable was later reconstructed from the exact parent production files and identical runner, matched byte-for-byte and reproduced the failure again. The candidate was restored byte-for-byte afterwards. [validation.json](validation.json) binds both original runs and candidate logs to those hashes.

## Focused checks

- New earlier/later wake cases: **2 PASS**; original was 1 FAIL / 1 PASS.
- Existing Owner actor cases 51,54–56: **4 PASS**. These cover cooling readiness, failed-read recovery past the deadline with a positive re-arm interval, a deadline crossing before automatic wake arming, and draining the same deferred original operation.
- Existing direct condition-waiter cases: **2 PASS**.
- Direct continuation store suite: **20 PASS**.

Total: **28 focused PASS**. Skipped Owner cases are excluded. This is not the full Owner suite or full regression. No new UI text/layout or timing-budget test was added.

Explicit build and execution commands are in the manifest. To reproduce the baseline, use the recorded parent production source with the identical candidate test runner and test stanza, then run `test/test_keeper_owner.exe test retry_deadline_rearm --verbose`. The candidate uses the same command. Dependency: the test stanza explicitly declares `eio.mock`; it is not a production dependency.

The superseded-sleep cancellation and original Owner-switch cancellation are inspected source behavior. An arbitrary chain of replacement races, explicit timer-fork failures and live clock corrections were not forced by these tests. Full regression and CI were not run; latest full-regression run/head/TARGET_SUITES were not inspected. The candidate was not installed and operating latency/UI were not measured.
