# Actual native server startup recovery

This bounded process experiment passed for binary source
`c52f799e52d3683bd2a4c624f0f6adfe36015ec9`, executable SHA-256
`373ced2eb4897f60d82a0c4b4b7340865e933f0e181a268906ddc595c9034af7`.
It does not establish execution of combined candidate `d9ba3f5` or the operating
installation. [Producer result](../2026-10-27-schedule-candidate-runtime/producer-result.json)
records **Minimal manual checks40374265429**, execution head
`9377c7f3025d68e3856d2afd3762468dabc77813`, ref `main`, source input c52,
completed/success. The [original receipt](../2026-10-27-schedule-candidate-runtime/native-receipt.json)
and both owned servers' observed health bind the source and binary digest.

## Observed behavior

1. An owned disposable base used a source-bound dead-loopback provider fixture,
   two create-only/manual/paused Keepers and an ephemeral port. Canonical HTTP
   Admin creates stamped human_operator and produced two distinct one-shots.
2. A macOS directory/ledger vnode watcher observed the original definition and
   exact genuine Running wake. The kernel confirmed SIGSTOP of owned PID83210;
   the stopped ledger retained attempt `01a179a6-ebe7-7000-8477-0a1e57e839c8`.
   No ledger JSON was manufactured or rewritten by the controller.
3. The original lease's published expiry was observed for about120 seconds;
   neither its TTL nor bytes were changed. A was then intentionally SIGKILLed.
   Stopped, post-death and failed-startup ledgers are byte-identical, SHA-256
   `6b8ea6f236d88ca33bbb5b56a38a022c30d686c2472521e359358efb4b98d1f7`:
   original Running and control Due, with no control wake.
4. The controller created only an owned directory at the real atomic staging
   path `schedules.json.tmp-atomic`, then started fresh native server B. Its first
   recovery failed with the actual `openat: Is a directory` persistence error.
   First tick: scheduler degraded, success0/failure1/dispatch0. The original
   Running and due control remained unchanged; the observation was after the
   control's actual due time and after that failed cadence.
5. Removing only that same owned directory let the **same B process/runtime**
   recover on its next tick. Runtime ID
   `01a179a8-c42d-7000-9223-d9c4b029a87f` stayed the same. The old attempt became
   failed/process_interrupted; two fresh attempts were accepted. Scheduler
   success1/failure1/dispatch2 and both exact occurrences appeared in the durable
   paused-owner queues. Initial/final owners remained manual, paused, zero-turn,
   with no last runtime attempt. B exited0; no final cleanup forced kill occurred.

The controller's42 checks are all true. [Its original summary](summary.json)
deliberately leaves the automatic outcome at
`bounded_checks_passed_requires_startup_cause_review`.
[Root's original-cause review](root-cause-review.json) read the raw health error
and B log before interpreting the bounded observation as PASS. A fresh independent
review session also read the complete controller, captures, producer receipt and
c52 recovery/consumer source and found this bounded proof sufficient. Neither
review reran the experiment or establishes formal GitHub approval.

[Selected health](health-selected.json) separates original HTTP body hashes from
controller-snapshot and derivative bytes. [Selected log](server-B-selected.json)
preserves exact source line numbers/text. [Manifest](capture-retention.json)
distinguishes original captures and selected derivatives. Raw API/status/log and
keeper metadata remain ignored. [Invocation reconstruction](execution-reconstruction.json)
is explicitly post-run: wait_seconds600 is an observer envelope, not a product
limit; Python version was observed afterward, not captured at process startup.

For COMMENT 5657993607 F1, the original ignored run is
`artifacts/schedule-actual-repair-20261027/runs/startup-recovery-2/`
in the evidence checkout. Its `http/startup-failed-health.json`
(`cb1b70d09952f6c6ed26603778f9f885c4c2c4f7d093105c23559c87de880fce`,
26681 bytes) contains `schedule_runner.last_error`; the corresponding original
HTTP body is `http/00067-response.bin`
(`4b99fd4dc30a4cab7ff173fdac7bd98b2060138186ee008e35c06cdfbec5d4a9`,
20963 bytes). The first [selected health observation](health-selected.json)
retains that exact error value. `server-B.log`
(`9461dcfd063f48dfe4601a2064e776ed4ab3467beb518077520d3ef0028cd879`,
22440 bytes) records the failure at original line136 and recovery at line150;
[selected log](server-B-selected.json) retains both lines verbatim. These
committed selections are derivatives, not copies of the full original files.
F2 remains unverified: the experiment did not capture the intermediate Due
state between interrupted Running and the new accepted attempt. No source
inference closes that observation gap.

## Limits and setup failure

Running observation and SIGSTOP have a race. This is **not proof that all consumer
effects were absent before the stop**. It proves the retained Running attempt,
first startup persistence failure/dispatch block, and same-B recovery/enqueue in
this experiment. The intentional first SIGKILL is a fault, separate from final
cleanup. The scheduler recovered to ok; full health **overall_status remained
degraded**. Do not call this whole-runtime health or installed readiness PASS.

This does not establish F5's process-local pending rejection-intent survival,
model execution, arbitrary external-effect exactly-once, power-loss behavior,
all race schedules, busy continuation, visible TUI or whole-feature PASS.
No operating server, original PR, installed binary or other worker was changed.

The first setup run failed **before creating any schedules** because the current
Python kqueue object lacks context-manager support. [Failure](setup-failure.json)
and [summary](setup-failure-summary.json) remain unchanged; its server exited0.
The separate v2 uses contextlib.closing, with an actual owned-file vnode capability
check recorded in [the derivation](controller-derivation.json). No product logic,
scenario or assertion was weakened. Both controller source captures retain their
original bytes as `.py.txt`; do not execute them in this retained location. Place
the chosen source under a checkout's `artifacts/schedule-actual-repair-20261027/`,
provide explicit verified identities and use a fresh output directory.
