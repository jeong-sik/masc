# Acceptance during buffered reasoning

Base: 8c41e7120c83ffd5acc6cdacce055c76e184ae05.

An actual stream projection fixture admits a provider-exposed reasoning delta with a typed generation/scope owner before its buffered preview flush. Delivery is still sending, so the previous acceptance guard regressed it to queued. RED: /tmp/chat-buffered-reasoning-acceptance-red-20261012.log.

Acceptance now consults the existing typed response ownership (floor/current/partial scope and phase) as well as delivery state before granting initial queue/opening status. It does not invent hidden reasoning or create another lifecycle mirror. The fixture confirms state preservation before flush and exposed reasoning preservation after flush.

The first post-fix run passed the status checks but its final trace assertion used a nonexistent kind 'thinking'; corrected to the actual typed 'think' contract. Final keeper-stream suite passed 101 tests, and TypeScript noEmit exited 0. Log: /tmp/chat-buffered-reasoning-acceptance-focused-20261012.log. Source/projection evidence only; no actual provider/runtime/browser screenshots, CI, approval or installation. Initially unbound operation-source admission needs a separate boundary check.
