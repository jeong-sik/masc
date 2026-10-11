# Audio broadcast row ownership

Confirmed failure: noteKeeperChatAppended optimistically attached a broadcast audio clip to the first assistant whose text matched. Two durable assistant rows with identical prose caused the second row's clip to appear on the first before history hydration. The actual action fixture failed before the source change.

Correction: remove text-based attachment and its unused function. Notifications invalidate persisted history; validated REST audio remains on the exact durable row. No text/substring heuristic or synthetic event identity is introduced.

Recovery finding: after a successful hydration, a forced refresh failure deleted the fetch guard. An inactive transcript then ignored its next notification. The new failure/recovery fixture failed before fixing the guard. Notifications now also admit existing typed successful hydration state, retaining future invalidation for previously loaded transcripts without another registry.

Validation: keeper-actions and keeper-state suites passed 168 tests; TypeScript noEmit and diff checks passed. Independent source review is distinct from formal approval. Supplied API responses/fake timer execution prove consumer and asynchronous hydration behavior; actual network latency, provider operations, installed runtime and screenshots remain unverified. Audio visibility waits for authoritative hydration.
