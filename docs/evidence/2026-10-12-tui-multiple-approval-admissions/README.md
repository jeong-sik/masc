# Multiple approval admissions

Base: 90707d571af803abd0cc5d40cf9843de69852f12.

One pending option lost the earlier approval whenever another request arrived.
Retain all observed admissions by typed approval identity, most recently requested
first. Pending replay does not duplicate or reorder admissions; conflicting call
correlation is diagnosed. Settlement finds the matching admission and removes
only that entry. Settled replay protection remains operation-bound. Runtime
attempt observation cannot substitute for an approval settlement.

The single-admission accessor now means the selected /approve or /deny target;
its interface documents that choice. The all-admissions accessor exposes retained
state. The attention projection includes the selected actionable question and
other pending questions. Held-call classification considers all approvals and
only uniquely correlated MASC calls; native observations remain native activity.
Progress summaries retain the pending tool names. This is implemented projection
behavior, not observed rendered-screen proof.

Artifacts: /tmp/masc-tui-multiple-approval-admissions-20261012/.
Actual parent/current approval event arms and unique-call lookup/update functions
run in minimal typed surroundings. The parent single option has a list adapter
only to compare pending cardinality; current accessors are production functions.
Parent exits 1 for loss/duplication of pending admissions. Current exits 0 for
both admissions, idempotent pending replay, selected focus, either settlement
order, settled replay refusal and eventual individual completion. These probes
do not execute runtime-attempt reduction or progress/attention projection.

Three changed OCaml files passed syntax-only parsing; diff whitespace check
passed. Registered state fixture adds both settlement orders and attempt-change
retention but is unexecuted. Full typecheck/build, provider approval ingress,
full transcript replay, installed runtime, UI/screenshots, CI, formal approval
and merge remain unverified. Unsolicited settlement before a surviving request
and authoritative server refresh remain separate gaps.
