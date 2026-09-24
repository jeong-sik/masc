# Codex wire encoding: source and verification scope

The context preparation work in #38799 leaves final JSON serialization in
`Runtime_codex_app_server.with_spawned_client.send` on the protocol owner.
That path encodes the full request and validates its UTF-8 before writing.

This change submits only immutable encoding and validation to the existing
CPU pool. The owner awaits the result, writes the JSON line and advances the
protocol. Worker submission, queue wait and pipe write all share the existing
admission timeout capped by the turn's declared wall-clock ceiling.
No I/O, hooks or shared protocol state move to the worker.

## Review and tests

Adversarial review found the first version's worker queue wait outside the
existing timeout. Review response moved it inside and added coverage:

- Existing transmission boundary scenario runs inline and with one worker:
  interrupted large writes emit no transmission callback, a successful escaped
  Unicode payload reaches the child exactly, and provider rejection retains
  the completed-write receipt.
- Dynamic tool and transmission callbacks retain their original domain.
- A worker held by a promise prevents encoding from starting. Both admission
  timeout and wall-clock cap produce typed pre-acceptance timeouts with no
  bytes in the child capture and no prompt callback. The worker is released
  on success, assertion failure and cancellation.
- Invalid developer instructions retain the producer field in the error and
  never write the invalid thread request.
- Fixture EOF exits before recording an empty request.

`git diff --check` passed. No local build or test execution. The focused
`test_runtime_codex_app_server` CI is required for execution evidence.

This is a scheduler isolation change. Small-message queue overhead, sustained
throughput, live scheduler latency and the overall 0.1ms target are unmeasured.
