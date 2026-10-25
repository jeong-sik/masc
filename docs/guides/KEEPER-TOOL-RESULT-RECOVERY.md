# Keeper tool result recovery

A vendor turn can finish before its admitted tool. The host retains the completed tool response in the Keeper-owned outbox. A previous functions.exec cell is transient; recovery consumes the saved response and does not resume that cell or execute the original effect again.

## Automatic result delivery

After a durable receipt is stored, its SHA256 identifier is submitted as a typed Tool_result_ready event through the existing Keeper event queue. The notification contains no arguments or result body. Startup and the existing maintenance pulse rediscover unread receipts, so a lost in-memory wake does not discard the obligation.

Queue admission, wake hints, turn start and queue acknowledgement are distinct from delivery. Only successful Codex settlement acknowledges the exact loaded receipt snapshot. A failed recovery turn leaves the receipt available for another normal maintenance pass. A newer receipt added after the snapshot remains unread.

Normal Keeper lifecycle decisions still apply. Recovery does not start an absent owner, unpause a Keeper, override desired state, or restart container services. Startup owner restoration follows the configured activation mode and existing lifecycle. The automatic model wake currently requires a nonempty Codex-only route: every reachable candidate must resolve to Codex. Quota ordering and fallback may select another candidate, so a Codex entry alone is insufficient. Mixed routes, other clients, and unavailable or unknown candidates retain their receipts. A previously queued notification for an unsupported current route is retired without deleting the receipt or blocking unrelated work; returning to a Codex-only route makes the receipt discoverable again.

Malformed or unreadable outbox entries fail closed and remain on disk with an error log. The recovery process does not fabricate a missing response, discard corrupt evidence, or repair unknown data by rerunning a command.

## Verified artifact materialization

Peer handoff uses an exported artifact reference and a recipient-relative sandbox path. A host path alone is not file delivery. Materialization reads the recipient through the contained sandbox backend. Exact existing bytes complete without another write. Otherwise it invokes the original authorized writer at most once, then reads one byte beyond the expected length to distinguish the complete artifact from a matching prefix.

An uncertain or post-effect runtime failure can be recovered when the recipient bytes exactly match the source. Approval deferral, policy/workflow/dependency/cancellation decisions and proven pre-effect failures remain authoritative. A completed write whose verification fails remains an explicit post-effect failure, preserving its original authorization, typed result, artifact roots and file-change evidence. It is never silently rewritten as an automatic retry.

## Verification scope

Focused source tests cover restart discovery, duplicate notification, failure followed by retry, exact snapshot acknowledgement, paused owners, corrupt entries, route changes and recipient reconciliation. Tests using callbacks or a Docker stand-in do not establish actual microVM behavior, crash durability, full fleet latency or installed runtime state. Those require separate execution evidence for the exact candidate.

Cold VM preparation, filesystem reclaim and Apple Container control-plane failures remain separate operations. This recovery does not remove maintenance work or restart a healthy backend merely because a client deadline elapsed.
