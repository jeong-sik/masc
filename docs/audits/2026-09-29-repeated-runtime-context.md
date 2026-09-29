# Repeated context on official-client resumes

## Observed behavior

On 2026-09-29, the live runtime rooted at `<base-path>/.masc` retained the same
Memory OS Recall in two successive Codex resume inputs for `hole-finder`.
The session was `01a0ecf2-f6d4-7df2-9442-e0334e3ce21b`.
Both inputs contained revision 347, updated at `2026-09-29T11:25:08Z`.
The SHA-256 of the extracted ordinary Recall block was
`5801795c6fdfaa1fb6b193cc5bfe8ef59fa26f70effc54ca19bf634d22e16422`.

| Resume input (UTC) | Previous reported input tokens | First subsequent reported input tokens | Difference |
| --- | ---: | ---: | ---: |
| 11:54:38.896 | 118,884 | 179,753 | +60,869 |
| 11:57:46.672 | 185,418 | 246,053 | +60,635 |

These are provider `last_token_usage.input_tokens`, not conversation-total
usage or a conversion from bytes. The differences also include other input;
they do not measure the Recall block's token count in isolation.
The native rollout is under
`official-clients/codex/<account>/sessions/2026/09/29/`, filename
`rollout-2026-09-29T20-35-46-01a0ecf2-f6d4-7df2-9442-e0334e3ce21b.jsonl`.
The two response-item inputs were at lines 187 and 211 when inspected.
No private memory text is reproduced here.

## Cause and scope

- Codex called the shared context host without `composed_context`. The host
  therefore compared the complete carrier. A changed clock or World State
  caused the unchanged Recall inside that carrier to be sent again.
- Muse and Antigravity passed an empty held-context list on every resume and
  stored no delivered block digests. They had the same failure even when the
  complete carrier was unchanged. This finding is from source inspection;
  it is not a live replay of those providers.
- Claude already passed the block witness and the acknowledged held context.
  Its unchanged-block suppression is preserved.
- Agent Core's `Agent_turn.prepare_messages` adds the carrier to the request's
  `effective_messages`. The pipeline persists its original conversation plus
  the assistant and tool results, not that synthetic carrier. Tool schemas
  are request fields. No equivalent duplicate-persistence defect was found
  in those inspected paths.
- Shared assembly combined ordinary Recall and the Librarian working-context
  index under one block identity. A revised Librarian artifact reference
  therefore replayed unchanged ordinary facts on every official-client lane,
  including Claude. This is a source-confirmed coupling, not a measured
  provider-token attribution.

## Correction

All three affected adapters receive the assembly's typed block witness after
the preparation hook, record delivered block digests on a fresh session, and
compare against the acknowledged frontier on resume. Unchanged blocks stay
out; changed blocks are sent in full. Operator notes retain their explicit
repeat-delivery semantics. A replacement session still receives its context.

Muse and Antigravity retain their canonical-history guard. When an incomplete
claim is released, its new held-context digests are cleared: recovering the
previous canonical snapshot does not prove the new blocks were delivered.
This permits a safe resend after failure instead of suppressing unsent memory.
Muse also clears held digests when its host reports that compaction rewrote
context, including on the host-stop settlement path. A reported no-op keeps
them. Antigravity's current transport exposes no compaction notification;
retention through an invisible vendor compaction is not established here.

Ordinary Recall and the Librarian index now have separate typed block
identities. A Librarian-only revision sends its updated reference without
replaying unchanged ordinary Recall. Both remain first-round context; the
Dashboard decodes and labels the new `librarian_working_context` identity.

This change does not remove context already present in vendor sessions,
implement partial updates inside a changed Recall block, or attribute Recall
and Tools separately in provider tokens.

## Validation

Native fixture regressions exercise the production adapters and capture
transport requests. They cover unchanged Recall with changing World State,
changed Recall delivery and later suppression, and failure/retry behavior.
A shared-host regression verifies that a Librarian-only revision does not
replay ordinary Recall. The shared session-store regression verifies that a
spawn failure does not certify an undelivered Recall block. Muse fixtures
cover Recall redelivery after compaction and continued suppression after a
reported no-op.

Build and behavioral execution belong to GitHub CI under the repository
execution protocol. Fixture success does not establish live deployment or
post-deployment token savings.
