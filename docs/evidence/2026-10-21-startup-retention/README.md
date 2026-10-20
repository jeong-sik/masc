# Startup retention and Keeper readiness

Observed source: `533296db987ad10a6e7b3be990788378e07d7462`.
Parent change: installed Dashboard digest scheduling, PR #44437.

During the operator's graceful runtime handoff on 2026-10-21 KST, startup
JSONL pruning began at 02:09:26. Keeper autoboot waited on this task. At
02:11:28 the existing 120-second guard marked it failed and released the
barrier; pruning actually completed at 02:11:46. The guard did not stop the
worker. Its degraded startup error remained after the work finished. These
timestamps establish the dependency and delayed completion, not which store
or syscall accounts for the elapsed time.

Retention already runs through the same function during normal serving in
the periodic maintenance lane. Its held-directory ownership checks, store
mutexes, declared stores, retention windows and deletion rules are unchanged.
Session restoration reads agent session files; retention does not delete
that session directory.

Only restoration remains in the Keeper readiness dependency. Startup retention
runs once in the common HTTP/stdio post-readiness lane. It shares the existing
switch-owned maintenance runner with microVM guest collection. The runner logs
start, elapsed completion, ordinary failure and cancellation. Cancellation
propagates, while ordinary maintenance failure does not fail server readiness.
Pruning no longer catches errors internally and then appears to finish normally.
Task constructors select observation names; callbacks explicitly supply the work.

Behavior coverage holds retention open while restoration completes, verifies
that restoration still holds the barrier, isolates ordinary retention failure,
and checks shutdown cancellation for both maintenance task kinds. The previous
group-name/list-shape assertion was replaced by those lifecycle observations.

Changed source syntax and whitespace were checked. The focused native run
[39467102729](https://github.com/jeong-sik/masc/actions/runs/39467102729), at
`53846754dfcd77a0910c0a4f610f075532f5d109`, passed 117 bootstrap cases, including
held retention and ordinary maintenance failure. Its microVM suite passed the
maintenance lifecycle and cancellation cases but failed one of 95 cases: the
existing remote-endpoint fixture did not create the Keeper runtime directory
before preparing its GitHub identity. The fixture now creates that prerequisite,
as the guest-reuse identity fixture already does. Production identity checks
are unchanged. The whole run failed; the corrected head needs a new focused run.

Installed startup latency remains unmeasured; no improvement time is claimed.
