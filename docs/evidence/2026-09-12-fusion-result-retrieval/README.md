# Fusion result retrieval and input limits

Read-only evidence from source `2578d7fec3061b0a8a05301eb465ae0521ce5461`,
Fusion run `kmsg-f381606a185bf86825c3f99ffd36e185`.
The original unlisted Board post is `p-c0bb49d30e7a617ea6596d100e845215`.
Its `origin.fusion_run_id` and originating turn 408 are durable; `meta` contains
both full panel answers, synthesized judge advice, source context and explicit
partial tool-trace coverage. GLM and Codex both answered. The GLM judge recommends
C as primary with B adapted to silent-choice support; Keeper adoption is a
separate decision.

Keeper turn 411 attempted a different post ID,
`p-c0bb49d30e7a617ea654d100e845215`, in provider round 748. The failed lookup's
prose said deleted or expired. Three successful Edits in round 750 then recorded
incorrect provenance: three panelists, `verdict_insufficient`, an A+C
recommendation, and alleged TTL loss. The actual post remains present; its
expiry was seven days after creation. The before/after blobs of all three Edits
were read and checked against their source hashes and exact replacements.
Delivery and file effects therefore do not establish faithful result consumption.
The generic Board not-found response is a separate repair.

## Model input evidence limit

The retained `masc.provider-input-snapshot.v1` for turn 411 uses the last request
wire observation, captured at 1789219046.512944. It has 176 projected messages,
base system prompt 8,368 bytes and wire body SHA-256
`393957f512574896eda9cbfd250103e26cb6c54fa30dc5ce41ff7f6d8a40f321`.
It does **not** reconstruct the complete first request of that Keeper turn.

The runtime manifest records extra system context of 80,318 bytes on provider
round 748, digest
`9e328f4dff13e7fe82f55f1bf2d7c0edc1a2cb5eb350d95963d1833d7d68c6e9`.
Rounds 749–751 show absent computed extra context after post-tool block filtering.
The first observed assistant text says it received a Fusion preview and needs
the full text. Source inspection confirms the completion answer is projected
through a 480-byte preview. The correct full durable wake payload is therefore
not evidence that every provider request contained that full answer. The full
first-round extra-context body is unavailable in the retained snapshot.

Local allowlisted evidence (not portable artifacts):
`/tmp/masc-fusion-consumption-2578/receipt.redacted.json`,
`deliberation.redacted.json`, `delivery-ack.redacted.json`,
`consumption-edits.redacted.json`, and `provider-input-limits.redacted.json`.

## Bounded repair and validation

The existing `masc_fusion_status(run_id)` reads the original Board-origin evidence
through the same Keeper ownership check used by `Fusion_decision`. Full original
metadata is returned without summarization, with the same evidence hash that
Keeper decisions reference. Registry metadata can be absent while original
Board evidence is available. Keeper choice remains separate and is never
inferred or created by a read.

The completion preview includes a managed instruction to use the canonical run
lookup and record an independent adopted/rejected/modified choice. That lookup
uses the typed completion's run ID directly and is outside answer truncation.
This does not compel agreement with the judge or claim model comprehension.

Feature tests read durable evidence after registry absence, compare both original
panel responses and source context, verify the decision's evidence hash and
ownership isolation, ensure reads do not adopt advice, and ensure a long preview
retains the canonical retrieval instruction. OCaml parse-only and TOML parsing
are checked locally; native tests run at the exact-head CI finishing boundary.
No local build or live runtime mutation was performed.
