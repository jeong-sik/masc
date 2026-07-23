---
status: withdrawn
last_verified: 2026-07-13
---

# Withdraw policy-classifying Keeper autonomy proof harness

The former harness classified Tool calls into policy denial, approval,
precondition, and zero-evidence buckets, then treated coverage counts as proof
of autonomy. That taxonomy recreated the deleted policy hierarchy and is
withdrawn.

Current observability records source Tool calls, results, Keeper/turn
correlation, runtime/model provenance, and typed boundary errors. Reports may
aggregate those facts, but a count or bucket does not authorize execution,
change a Keeper lifecycle, or prove semantic success. Semantic evaluation uses
the configured LLM or an explicit nonblocking Gate when requested.
