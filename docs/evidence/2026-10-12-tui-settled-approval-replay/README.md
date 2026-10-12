# Settled approval replay

Base: 960476b3028a09c4d3f4c0126e31750b19d52fad.

A successfully correlated approval settlement removed the pending prompt but
retained no admission identity. Replaying its request could reopen the prompt,
clear the last settlement or displace a newer wait. Retain observed settled
approval ID and call correlation for the operation lifetime. A matching replay
leaves state unchanged; conflicting correlation records a diagnostic and cannot
replace a newer wait. Only accepted settlement establishes this retained fact;
unsolicited settlements do not fabricate an admission. Retention has no arbitrary
time/count window and survives runtime attempt changes.

Artifacts: /tmp/masc-tui-settled-approval-replay-20261012/.
Actual parent/current approval event arms and call lookup/update functions run
with minimal typed state/event surroundings. Parent exits 1 for settled replay
reopening admission. Current exits 0 for settled replay refusal, newer wait
preservation, conflicting correlation diagnosis and newer matching settlement.
This does not execute canonical approval ID parsing, runtime attempt reduction,
producer ingress, full transcript replay or visible UI.

Two changed files passed syntax-only parsing and diff whitespace check. Registered
state fixture is unexecuted. Multiple simultaneous approvals still share one
focused pending slot; this unit does not prove complete parallel approval handling.
Full typecheck/build, runtime/provider integration, UI/screenshots, CI, formal
approval and merge remain unverified.
