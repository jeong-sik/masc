# Reserved interruption of committed Tool observations — #27890

This proof layer continues #45999 without changing production code. The actual execution writer/scope commits a Tool effect, result and successful root terminal before observation delivery. A real Event_bus publication accepts the first canonical ToolCalled occurrence, then the publication callback raises Sys.Break or cancels an actual Eio.Cancel.sub child context and calls Eio.Fiber.check.

The exception is caught outside that child context. The same production coordinator is flushed again from the healthy parent context. Assertions require the first accepted/unacknowledged occurrence to replay identically, then the canonical completion to follow in source order. A third flush must not repeat acknowledged observations. The effect count stays one and a fresh authoritative read has identical events, cursor and successful terminal. The test therefore checks actual durable facts and receiver acceptance around the mutex/cursor boundary, including real cancellation state rather than only a constructed Cancelled exception.

This isolates the coordinator and receiver after canonical settlement. It does not prove cancellation ordering inside Agent.run or MASC post-hooks, retention, OS restart, provider HTTP, installed runtime, dashboard, whole regression or whole #27890 acceptance. Parent #45999's separate 115-case result does not prove the new controls.

Requested run [40213817713](https://github.com/jeong-sik/masc/actions/runs/40213817713) at exact `1ede23a6877fc4834e30a98fc6cd096324b11981` selects only `packages/agent_core/test/test_execution_projection` (six existing cases plus two new controls). **SUCCESS: all eight actual cases passed**, including both reserved-publication controls and their cursor/identity/effect/terminal assertions. Parsing and whitespace pass; no local Dune build/typecheck was run.

Two independent source reviewers returned PASS at that source head against parent `8f2613d4e7b72a9c686838a0bab7124a68302a52`, full diff SHA256 `c3ef4d6479679a7d914f4d203b763c32a18f4abe0437eade5cb5e81bd4c5ac5d`. Those are source assessments, not formal GitHub approval or execution. PR #46000 was draft/open/unmerged at that source-review boundary. Local gh stack adopted the branch against #45999; native submission reports repository disabled and REST stack:null.

## Final result

[40213817713](https://github.com/jeong-sik/masc/actions/runs/40213817713) completed SUCCESS at exact `1ede23a6877fc4834e30a98fc6cd096324b11981`: eight actual cases PASS. Both new controls reached all propagation, acceptance, replay, acknowledgement, effect-once and immutable canonical terminal assertions. The excerpt retains each control separately and records the complete raw-log digest/size. Four source hashes are unchanged in the evidence follow-up. This completes this coordinator proof, not joined Agent cancellation or the original whole issue.
