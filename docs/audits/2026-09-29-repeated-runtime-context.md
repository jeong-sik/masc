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

Codex and Muse receive the assembly's typed block witness after the preparation
hook, record delivered block digests on a fresh session, and compare against
the acknowledged frontier on resume. Unchanged blocks stay out; changed blocks
are sent in full. Operator notes retain their explicit repeat-delivery
semantics. A replacement session still receives its context.
Codex observes completed `contextCompaction` items directly and retains
invalidation from typed usage estimates for the whole attempt:
an observed compaction followed by a normal request must not restore the old
held digests merely because the final usage describes that later request.
Separate four-tick regressions cover a direct compaction item without an
estimate and an estimate followed by ordinary request usage. They verify initial delivery, compaction on resume,
redelivery on the next resume, and suppression once that delivery settles.

Muse and Antigravity retain their canonical-history guard. When an incomplete
claim is released, its new held-context digests are cleared: recovering the
previous canonical snapshot does not prove the new blocks were delivered.
This permits a safe resend after failure instead of suppressing unsent memory.
Muse also clears held digests when its host reports that compaction rewrote
context, including on the host-stop settlement path. A reported no-op keeps
them. Antigravity's current transport exposes no compaction notification.
It therefore retains an empty held set and resends carried context on every
resume. Suppression requires a compaction/reset witness; prior delivery alone
is insufficient. Its native regression explicitly requires unchanged Recall
on each resume.

Ordinary Recall and the Librarian index now have separate typed block
identities. On lanes with held-context suppression, a Librarian-only revision
sends its updated reference without replaying unchanged ordinary Recall.
The assembly assigns separate ranks to ordinary Recall and the Librarian
reference, preserving that order independently of insertion order.
Both remain first-round context; the
Dashboard decodes and labels the new `librarian_working_context` identity.

This change does not remove context already present in vendor sessions,
implement partial updates inside a changed Recall block, or attribute Recall
and Tools separately in provider tokens.

## Tick-by-tick state synchronization

Deduplication alone cannot synchronize a retained conversation. An empty
Recall previously disappeared from the next input, leaving its earlier facts
in the vendor history without notice of withdrawal. A read failure also
disappeared, so it could not communicate uncertainty or force redelivery on
recovery. The same applied to missing, corrupt or stale Librarian indexes.

Recall now explicitly communicates present, empty, absent, unavailable and
disabled states. Ordinary and source-bound memory have independent states.
A replacement snapshot marks prior facts as historical; an unavailable state
marks them unverified without claiming deletion. Librarian reader loss and
unavailable indexes withdraw the old reference's current status. Repeating
one state produces identical text; recovering the same old content produces
a new delivery after the intervening status.

Every identical-fact commit advances the store revision and update time.
Those bookkeeping fields no longer change the model-facing Recall payload;
they remain in the durable store and inspection tools. Rendered fact content,
category, origin kind, displayed basis, source identity and verification
remain part of the payload. Detailed derivation metadata continues to be
available through its existing tools.

The native Codex fixture follows 27 ticks in the same session: A, unchanged A,
B, empty, unchanged empty, unreadable, unchanged unreadable, restored empty,
absent, unchanged absent, restored A, then 16 identical-fact recommits with new
revision/time and changing clock. It checks actual transport content and that
held delivery records remain bounded by the two block identities. Separate
fixtures exercise reader loss, source validity, failure and compaction.

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

After deployment, compare Codex/Muse provider-reported per-request input-token
deltas between consecutive resumes of the same native session and model,
separating unchanged-memory ticks, actual content changes and compaction
boundaries. Verify duplicate Recall occurrence counts in native inputs as
well. A lower net average caused by compaction alone is not evidence of this
fix; no expected numerical saving is asserted before that measurement.

The first PR check and targeted run at `aa6e1a1d92` failed compilation because
the TUI block-label match did not include `Librarian_working_context`. The
missing arm was added with the cycle changes. This failure did not execute
the behavioral cases and is not a behavioral PASS.

The targeted run `36569639435` at `08bc66b08d` executed all ten selected
suites. Muse, Antigravity, Claude, session-store, turn-record, ordinary-memory,
memory-write, Librarian recall and TUI context-inspector suites passed. The
three new Codex cases failed before their first native request because the
fixture read `requests.jsonl` before creating it. Fixture setup now creates
the empty capture file before a test counts prior requests. These older-head
results are diagnostic evidence, not validation of later commits.

At `6770a82319`, targeted run `36572762990` passed 10/11 suites, including
the 27-tick Codex cycle and both compaction sequences. Two production-wire
assertions still assumed dynamic instructions were the carrier prefix; they
now verify the exact section occurs once after explicit memory status blocks.
The PR gate additionally caught duplicate cache ranks; Librarian now has its
own rank between ordinary Recall and dynamic context. New-head CI is required.
