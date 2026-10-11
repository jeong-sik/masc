# Assistant stream target role and domain

Base: 5bbcc4c8f860b43a461b2dd68bc51363d5108e66.

Three parent projection fixtures failed: assistant text appended to a user-authored row; assistant text appended to a tool result row; and an operation journal frame changed an autonomous response with null operation provenance, including its sequence. RED: /tmp/chat-stream-target-domain-red-20261012.log.

The common stream admission boundary requires the target role to be assistant. Autonomous rows additionally require autonomous source authority; existing exact turn checks then apply. These decisions occur before sequence acknowledgement and content effects. No text classification, parallel role mirror or guessed provider output is used. Existing own-operation continuation and autonomous journal fixtures still pass.

The keeper-stream suite passed 112 tests, TypeScript noEmit exited 0, and diff check passed. Log: /tmp/chat-stream-target-domain-focused-20261012.log. The counterexamples call public projection boundaries; they do not prove an installed caller sent these frames to the wrong row. No live provider/server/browser screenshot, CI, formal approval or installation is claimed. Caller-level routing and input interleaving still need full runtime proof.
