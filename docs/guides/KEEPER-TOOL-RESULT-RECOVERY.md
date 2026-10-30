# Keeper tool result recovery

A vendor turn can finish before its admitted tool. The host retains the completed tool response in the Keeper-owned outbox. A previous functions.exec cell is transient; recovery consumes the saved response and does not resume that cell or execute the original effect again.

## Automatic result delivery

After a durable receipt is stored, its SHA256 identifier is submitted as a typed Tool_result_ready event through the existing Keeper event queue. The notification contains no arguments or result body. Startup and the existing maintenance pulse rediscover unread receipts, so a lost in-memory wake does not discard the obligation.

Queue admission, wake hints, turn start and queue acknowledgement are distinct from delivery. Only successful Codex settlement acknowledges the exact loaded receipt snapshot. A failed recovery turn leaves the receipt available for another normal maintenance pass. A newer receipt added after the snapshot remains unread.

For a result produced during a Codex turn, a complete response write alone is
not receipt by the client. The current turn can settle a result only after the
client reports a matching successful `dynamicToolCall` completion for the same
call and response, and the Keeper accepts the completed turn. An absent,
cancelled or mismatched completion leaves the original result in the outbox.
Codex can synthesize failed responses that look like a tool's own failure, so
failed results remain available for the next recovery turn. A matching client
completion establishes client receipt, not that the final model input included
the result.

When retained results have identical fields apart from call identity, the
model-facing context can represent their common data once and list every
receipt separately in snapshot order. That order does not establish execution
or completion order. Each reference retains its call ID and, for a host
receipt, its producer-scoped physical invocation index. This representation
preserves arguments, responses and source identity; it does not combine tool
effects, alter retained files or acknowledge results. The ordinary individual
representation is used when no common data repeats, when sharing and its
explanation would not reduce the context size, or when a shape cannot be
represented safely. A smaller context does not establish that a particular
model consumed or interpreted the results.

Normal Keeper lifecycle decisions still apply. Recovery does not start an absent owner, unpause a Keeper, override desired state, or restart container services. Startup owner restoration follows the configured activation mode and existing lifecycle. The automatic model wake currently requires a nonempty Codex-only route: every reachable candidate must resolve to Codex. Quota ordering and fallback may select another candidate, so a Codex entry alone is insufficient. Mixed routes, other clients, and unavailable or unknown candidates retain their receipts. A previously queued notification for an unsupported current route is retired without deleting the receipt or blocking unrelated work; returning to a Codex-only route makes the receipt discoverable again.

Malformed or unreadable outbox entries fail closed and remain on disk with a Warn diagnostic. The recovery process does not fabricate a missing response, discard corrupt evidence, or repair unknown data by rerunning a command.

## Verified artifact materialization

Peer handoff uses an exported artifact reference and a recipient-relative sandbox path. A host path alone is not file delivery. Materialization reads the recipient through the contained sandbox backend. Exact existing bytes complete without another write. Otherwise it invokes the original authorized writer at most once, then reads one byte beyond the expected length to distinguish the complete artifact from a matching prefix.

An uncertain or post-effect runtime failure can be recovered when the recipient bytes exactly match the source. Approval deferral, policy/workflow/dependency/cancellation decisions and proven pre-effect failures remain authoritative. A completed write whose verification fails remains an explicit post-effect failure, preserving its original authorization, typed result, artifact roots and file-change evidence. It is never silently rewritten as an automatic retry.

## Verification scope

Focused source tests cover restart discovery, duplicate notification, failure followed by retry, exact snapshot acknowledgement, paused owners, corrupt entries, route changes and recipient reconciliation. Tests using callbacks or a Docker stand-in do not establish actual microVM behavior, crash durability, full fleet latency or installed runtime state. Those require separate execution evidence for the exact candidate.

Cold VM preparation, filesystem reclaim and Apple Container control-plane failures remain separate operations. This recovery does not remove maintenance work or restart a healthy backend merely because a client deadline elapsed.

## Apple volume creation after a client timeout

A timed-out Apple Container CLI does not establish whether its storage service finished creating the requested volume. The provisioning call performs one authoritative probe for the exact volume name. Confirmed presence satisfies the request as an already-present volume, without another create command or a claim about which actor created it. If that probe reports absence or cannot read authoritative state, the original create failure remains. Other command failures, cancellation, current deadlines and backend lifecycle decisions are unchanged.

This is reconciliation within the current provisioning call. It does not persist a pending provisioning operation or guarantee recovery across calls or server restart. It is separate from the durable Codex tool-result delivery described above.
