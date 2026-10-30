# Keeper bootstrap during held Session restoration

Issue #25899 / absorbed #24354. Production baseline is PR45889 head
`c288253aeb969ce4395693c0eaa946718c737192`. This layer changes only tests,
registration, evidence and changelog.

The existing nine Session tests preserve live queues/tombstones across actual
restoration but do not invoke Keeper bootstrap. This fixture connects the actual
Mcp_server.create_state_eio Session actor, Owner inventory with the production
operation runner, actual prompt/Gate/MCP-session restoration and public persistence
prepare/claim/start.
It writes one autonomous Keeper's real TOML/meta and explicitly declares a Docker
catalog pin. That pin is fixture configuration, not proof of a physical image.
The test supplies explicit runtime availability, not a model request or response.

Actual Session discovery opens its restore scope and reads real files. Its
existing after_discovery seam then waits on a promise. The fixture explicitly
arranges the pending restore inventory, invokes real start_keeper_loops, and
asserts a previously unregistered Keeper lane crossed its start boundary with no
exit observed while restoration remains held and pending. It releases restoration
and verifies the peer appears, original live object/notification survive, and a
concurrent unregister is not resurrected. Eio guard is enabled and the context
and guard are restored only after structured child cleanup. No Keeper boot,
registration, launch outcome or operation runner is replaced with a success stub.

## Scope of proof

This is a composition of public production components. The pending-task inventory
is an explicit fixture arrangement and the held operation uses the existing
Session test seam; it does not execute the complete activate_owner_state path or
intercept that path's own restoration worker. Crossing the lane start boundary
is progress, not a healthy-running verdict, executed model turn, container startup
or installed runtime. The wider auxiliary failure-isolation requirement remains.

The scenario synchronizes with real actor/promise/lane state, no sleep, clock
advancement or latency assertion. The standard targeted runner already supplies
its outer process hang backstop; no duplicate fixture timeout is added.
Adversarial review caught missing Eio_guard activation, now corrected. No local Dune/typecheck/executed success is claimed. The new
source parses and whitespace passes; actual execution will be requested separately.

## Observed earlier execution and stronger fixture inputs

Run40158656336 checked out aab2135c694aa7eb78c29a88ff77b0048d3b11cc and
completed SUCCESS: one actual component scenario passed in3.462s. Actual logs
show the Keeper lane boundary while restoration was held, pending remained
without a false failure, and release preserved live queue/object/removal state.
That measured duration is not a performance criterion or deployment proof.

The same logs exposed weaker inputs: the names-only agent files held `{}`, so
workspace readers rejected them for missing last_seen, and the fresh config
contained no shipped prompts. The current fixture writes agent rows through the
real typed codec and unpacks/checks shipped prompt assets before actual prompt
bootstrap, with a real system-prompt availability assertion. This strengthens
fixture fidelity without production changes. The earlier run proves its exact
old fixture, not successful execution of these updated inputs. New execution is
required; no current-head typecheck/test success is claimed yet. Its cancelled
parent cleanup log also is not a successful model-turn verdict.
