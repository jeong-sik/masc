# Durable Ask inventory after a Keeper stops

The isolated native Ask comparison exposed a real inventory defect before a
valid question-latency comparison could be made. A manual Keeper had one
persisted original question, but both clients received an empty fleet from the
same server. The server enumerated the in-memory Keeper registry; the manual
Keeper was deliberately not autobooted. Requiring it to run would hide the
durable-question failure.

The server source was `9e7c5d4f13cc551afb9fe9536bca785b69fead46`.
The old TUI source was `f7632e71601da3ce6c7b5a5e8a6b528bcf42fa4c`; the new
TUI used the server's source. Both used the same isolated workspace, fixture
bytes and 120 by 36 viewport. These were native binaries with local supplemental
dynamic libraries, not an installed operator runtime or a real-model trial.

| Boundary | Before, observed | After, implemented |
|---|---|---|
| Manual/offline Keeper has an original open Ask | Fleet returned zero Keepers and zero questions in both arms | Discover canonical owners from the durable Asked records; named and fleet reads include the original question |
| Answer that original question | Route required live Keeper registration | Validate and append against the original Ask; retain canonical first-winner and durable wake outcomes |
| A discovered log cannot be read | Successful empty projection was possible through permissive readers | Return an unavailable read so the TUI retains its previous questions |
| Counts and displayed rows | Separate store reads | Derive both from the same loaded fold |

The two native arms remain failed question-observation samples
(`fixture_unverified`), not successful early-Ask or first-action measurements.
The preceding collector attempt failed before either arm started because an
extracted executable lacked its executable mode. Both collector attempts remain
in the private history: one failed setup with no started native arm, followed by
one collector run with two invalid native arms. No Ask
latency improvement or Keeper resumption is established by this counterexample.

`observed.json` preserves only the relevant response fields from the two
native arms. Original Transport output, frames, request logs and complete
responses remain with the isolated collector artifacts; this projection does
not claim to reproduce their complete bytes.

The focused HTTP scenario uses the actual router and durable Ask store. It
unregisters the original Keeper, reads its original question through named and
fleet requests, rejects a foreign choice, records an answer, retains the
canonical duplicate-answer receipt, rejects an unknown Ask, and refuses an
incomplete inventory without rewriting the original answer. No UI wording,
layout or row-order assertions are used.

The subsequent [native read and answer-draft comparison](../2026-10-17-native-asks/README.md)
uses the repaired server at two viewports. It confirms the original offline
question is returned and can enter the actual TUI draft. Native answer
submission and Keeper action remain unobserved. The counts above describe the
original discovery attempts; the linked comparison retains the complete later
attempt history as well.
