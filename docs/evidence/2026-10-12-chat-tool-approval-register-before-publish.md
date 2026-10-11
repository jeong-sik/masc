# Register approval wait before publishing the operator request

Base: 662d22776bba76ede69d7f1f2d2884aef80ddb7e.

Source counterexample: the gate published REQUESTED before Registry.await installed the waiter. A publish consumer that immediately answers sees no wait, returns settled=false, and the gate subsequently parks unanswered. The new functional gate test answers synchronously from the actual publish callback and checks the decision and cleanup.

Registry.await exposes an optional on_registered callback, executed outside the mutex after registration and inside the existing cleanup protector. The gate publishes its request there. A remembered decision bypasses registration and emits only its remembered SETTLED observation, avoiding a request for a nonexistent live wait. Two existing late-answer event expectations were updated accordingly. A functional registry test checks publication failure propagates and leaves no waiter.

Validation: complete local source diff and direct tests inspected; git diff --check passed. OCaml tests/build were not executed: constitution execution_protocol forbids local Dune for this coding session. Independent source review requested; no RED/PASS execution, CI, runtime or screenshot claim.

Remaining: provider call-ID reuse still aliases waits; approval incarnation and all transport/event consumers must be repaired next. Registry counts and cancellation publication semantics require separate audit.
