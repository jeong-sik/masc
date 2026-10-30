# Keeper startup dependencies

Issue #25899, specifically absorbed #24354. Baseline main
`3cce9a517b25863c00b48cfb3dd79b994ebc1044`.

Autoboot previously waited for the whole lazy task inventory, marked a still
running task failed after a default 120 seconds, and slept another five seconds.
The only lazy task now is agent session restoration. Its actual worker continued
after the elapsed-time guard removed it from pending and reported failure.

Keeper startup already depends on explicit Runtime_startup_state availability,
typed persistence preparation/claim/start, and shutdown admission fences. Prompt,
Gate and MCP transport session restore precede the claim/start boundary. Agent
session discovery supplies none of that ownership: it discovers agent filenames
and merges them through the Session actor, preserving existing connections,
message queues and concurrent unregister tombstones. It can finish independently
without holding unrelated Keeper boot or inventing a failure from elapsed time.

This change removes the lazy inventory gate, its timeout/failure side effects,
the settling delay, their three orphan settings, and the obsolete timeout counter
from full-health publication and rollup. It retains actual task
completion/failure reporting and all real ownership/runtime prerequisites. The
remaining listener retry interval and its tests remain independent.

## Evidence and limits

Local parsing and whitespace pass. The receipt lists all 16 source hashes.
No local Dune build, typecheck or executed result is claimed. The selected
existing session_restore suite exercises real actor restoration concurrent with
live registration, notifications, unregister tombstones and overlapping discovery.
The health rollup and skill-catalog health suites cover the changed rollup API.
The bootstrap interval suite checks the remaining configuration and warmup cases;
obsolete literal tests for removed settings were deleted. Neither suite proves
actual Keeper bootstrap while a real restoration remains held. That integration
proof and installed/live behavior remain open requirements; no artificial
function-count/source-pattern test is substituted for them.

Independent source review is required. This bounded repair does not complete
#25899: sequential auxiliary starts still share an outer exception scope, and
per-component readiness/failure projections require separate evidence. No generic
dependency graph or new timing/limit knob is added.

Adversarial review caught the remaining health counter/rollup consumer graph;
root removed it, its public contract, and the tests for the deleted timeout.
Historical captured health artifacts were preserved as historical evidence.
