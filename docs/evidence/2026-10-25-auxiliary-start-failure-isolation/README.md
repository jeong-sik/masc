# Auxiliary startup failure isolation

Issue #25899 / absorbed #24359. Baseline parent
`f0f4f30c859eee320a3d1facbd487028813d9e46`.

The HTTP owner publishes readiness before optional startup work. Previously a
single outer exception handler covered the subsequent independent starts. An
early synchronous exception left later connector/refresh callbacks uncalled.

The Root now supplies one required callback record to a typed ordered runner.
The 21 callbacks retain their production bindings and order: caller notification,
scheduler probe, full-health refresh, heap roots, owner lanes, Discord, Slack,
Slack poll, iMessage, banner, gRPC listener/client, WS handler, transport providers,
and the seven dashboard refresh/prewarm callbacks. The owner-lane function retains
its authority-before-maintenance ordering; WS handler install and runtime-ready
publication remain coupled, as do provider registration and sealing. Banner paths
are read from the actual workspace config at its callback, without depending on
maintenance returning a tuple successfully.

Each attempt is Not_attempted, Starting, Returned, Failed with private cause and
original backtrace, or Cancelled. A synchronous non-cancellation exception is
recorded and later callbacks continue. Cancellation inside a callback is recorded
and rethrown with its original provenance; later callbacks are not attempted.
Between callbacks, completed attempts stay Returned and unentered callbacks stay
Not_attempted; cancellation still propagates before normal return. A callback can have
partial effects before throwing; this change does not invent rollback. The one
process-local registry belongs to this startup sequence, not a durable history.

Diagnostics run after the attempts, so a faulty logger cannot skip starts.
The owner remains ready and is marked degraded with all failed component names.
Full-health is invalidated on synchronous failure. A cheap health probe reads
current attempt evidence; full-health caches the same typed projection and rolls
up failed starts under its existing snapshot/freshness contract. Causes and
backtraces are absent from public JSON. Neither Returned nor an overall absence
of start failures means a transport is ready or its forked worker is alive.

## Defined checks and their limits

The new suite has five scenarios:

- Inject a failure at each callback position through the same production runner;
  every other controlled callback completes an actual HTTP exchange with a
  synthetic local TCP peer. Preserve the exact failure and throwing evidence.
- Hold a later callback after an earlier failure, observe Starting/Not_attempted,
  then retain both earlier and later failures without overwriting evidence.
- Cancel a real Eio context during a held callback; preserve exception/backtrace,
  stop later starts, and keep the independent TCP peer usable.
- Cancel between callbacks after a real HTTP exchange; no later callback enters.
- Exercise the actual health probe, warming full-health placeholder and rollup;
  retain failure/action information, exclude private causes and avoid duplicate
  auxiliary_startup fields.

The callbacks and HTTP peer in these tests are controlled fixtures. They test
runner continuation and real socket I/O, not successful Discord/Slack/gRPC
services or injected execution of the complete Server_runtime_bootstrap.run
assembly. Root bindings/order/coupling have independent source review, which is
separate evidence from execution. The lower gRPC listener suite exercises actual
bind acknowledgment/socket cancellation/H2 protocol; it also does not execute
this full Root assembly.

No local Dune/typecheck/executed success is claimed. Parsing seven changed/new
OCaml files and whitespace pass; source receipt records their hashes. Independent
adversarial and response audits found no P0-P2 before publication. Selected
execution will be requested after publication; full regression is unrun.

The #25899 umbrella remains OPEN. Asynchronous child-fiber exceptions retain
their existing structured-concurrency scope, blocking callbacks still wait in
sequence, and each gateway/listener owns actual readiness. This bounded repair
does not certify full bootstrap injection, healthy model turns, installation or
live fleet behavior. It adds no dependency graph, service timeout or numeric gate.

## First selected execution and repair

Run [40161241877](https://github.com/jeong-sik/masc/actions/runs/40161241877) checked out `115078e0d6d24b72fa596255ed6fdd27e3bf5171` and FAILED during compilation before selected cases executed. The new test referenced private `Server_routes_http_runtime.make_health_probe_json`, which is absent from its interface. The fixture now calls public `make_health_response_json` with `/health`, which selects the same actual probe builder. No production export or test-only wrapper was added. Earlier source COMMENT5641461022 missed this blocker and is superseded for test compilability. This is not a current-candidate execution success; the same three suites must run on the repaired head.
