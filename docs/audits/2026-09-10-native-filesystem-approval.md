# Filesystem authorization belongs to the producer

Native pre-tool approval treated direct Write/Edit as an interactive question
before the filesystem producer could resolve its target. That could park the
call in the native process-local 180-second waiter even when the producer
already owned the authorization decision.

The policy now delegates the two exact typed handlers to their own filesystem
boundary. For shared-host files, the producer validates a confined capability,
allows its own playground, and uses Keeper_gate for other admitted effects.
For endpoint-owned files, the remote producer admits only its own playground
and rejects external paths. No Execute approval is reused; each filesystem
call still traverses its own producer's checks.

Tests cover the native hook returning Continue without registering a waiter,
real Write/Edit dispatch changing a confined file under Manual Gate mode,
refusal of an outside target, and Manual filesystem Gate requests retaining
durable deferral. Composition nodes follow the same producer ownership.

This does not remove or fix every native approval timeout. Other tools retain
their current policy. No local build or live behavior proof has been performed
for this change; targeted CI remains required.
