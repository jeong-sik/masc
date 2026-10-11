# Board voice belongs to its delivery context

Base: `15eb7120b8af6fe452fb4fb75f173f7f3864d2ed` (#42422).

## Measured failures

Actual ComposerV2/BoardSurface components with the real voice hook and deferred microphone boundary reproduced four failures against exact parent product source: workspace replacement, broadcast-to-DM replacement, selected DM recipient replacement and mobile composer collapse all allowed the old permission completion to start a recorder. The candidate prevents that recording and releases the late stream's track. Ordinary text edits within the unchanged delivery context retain capture.

Independent review then found a P2 in the initial repair: comparing only the selection value ignored a typed mention overriding the actual recipient. Two additional actual component fixtures reproduced the issue on that candidate, with desktop selection still alpha while body became @beta and with mobile body changing its derived recipient. The repaired predicates reuse the existing recipient projection consumed by sending. Desktop derives deliveryKeeper once from mention.effectiveKeeper and uses it for voice ownership and submit; mobile uses its existing mobileMentionTarget. No new prose-matching heuristic or mention parser was introduced.

The initial SOURCE FAIL is preserved at `/tmp/masc-board-voice-recipient-finding-20261012/report.md`, SHA256 `3456f6616bdd3cde9f816592b61175e5fd1f9994d4c6433b862e31f950399e8a`. The source artifact was frozen from candidate backups during an explicit parent replay; it is not a review of the temporary parent bytes.

## Verification and limits

90 focused tests passed across the new actual Board context harness, Board composer/surface and voice lifecycle/shared composer harnesses. TypeScript noEmit and diff-check passed. Seven new fixtures cover six independently reproduced ownership failures and normal editing. The first recipient fixture incorrectly used an input event that did not change the controlled selector; it is excluded, and the corrected change-event fixture reproduced the failure. An unrelated missing Board flair mock warning was fixed; the final clean parent replay still reproduced all four original failures. The final mock returns the actual array contract.

This proves in-process component decisions and synthetic media resource release. It does not prove real microphone/network, completed provider runtime, installed UI, screenshots, CI, formal approval or merge. Voice recovery and complete async file preparation, streaming/interleaving/broadcast goal verification remain incomplete. Preliminary source PASS must be rebound to the final published head/base/full diff after the numbered fragment.
