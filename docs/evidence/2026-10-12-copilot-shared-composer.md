# Copilot uses the shared owned composer

Base: `b902c97ce7d271ec322fc11da917abac93e25f49` (#42416).

## Measured failures

Actual Dock DOM fixtures reproduced old text remaining after credential replacement and old Enter invoking send before the auth rerender. During the repair a recipient-switch fixture confirmed that rejecting the host send alone still erased the old draft; the ownership check must precede composer cleanup too. A route-switch fixture reproduced an old Overview context being submitted before a Connectors rerender. The first route fixture used an invalid work tab, failed typecheck, and is excluded from evidence; the corrected valid Connectors fixture also failed with the route guard absent and passed after restoration.

## Implementation

The private Dock textarea/buffer/submit path is removed. Shared ChatComposer provides credential-owned and per-Keeper drafts and structured input. A host ownership predicate checks the current credential epoch, selected Keeper and route snapshot before starter/send effects and before shared payload generation/draft cleanup. Keeper switches preserve each unsent authored input draft. Both simultaneously mounted surfaces read one immutable reactive snapshot of text, attachments and voice, partitioned by credential epoch and Keeper. Revision ownership rejects a stale handler before submission and compare-and-set clearing retains newly authored input published by the send callback. Utility slash commands clear only their owned text; actual message submission clears its owned full snapshot. Starter submission leaves independently authored drafts intact.

The existing block-to-attachment/display conversion is extracted unchanged into composer-message.ts, used by both Dock and Keeper panel. Dock forwards semantic user blocks, exact action identity and media/reference attachments into the common sending action with Copilot channel/context. A reference-only fixture uses the actual Dock controls, action, API/SSE decoder and request body, verifying the reference survives the wire and canonical input. Obsolete private composer CSS is removed from both stylesheets.

## Checks and limits

Initial 246-test validation did not cover simultaneous same-Keeper input surfaces. Independent review found a P2 at initial published head `f29c8bcd77859ba259639ea6908ede1a7c4fe52e`: a stale Dock snapshot could send old input and erase newer main-panel input. Actual simultaneous DOM reproduction failed before canonical snapshot ownership and passed afterward. A later review found utility slash commands cleared unsent media/voice; a valid typed URL-reference fixture reproduced that loss with the text-only clear absent. The first fixture used an invalid attachment kind, failed typecheck, and is excluded; the corrected fixture independently reproduced the failure. Review FAIL artifacts remain at `/tmp/masc-copilot-composer-review-finding-20261012/report.md` (SHA256 `f13c660c4b38338ffde68f12da22a2e9c37de0312cee455996755fad4c85fda7`) and `/tmp/masc-copilot-composer-slash-finding-20261012/report.md` (SHA256 `ec75569f722a47c686e702b65ea97927d4e167bd1fc87f651a889a174e0f6973`).

258 focused tests passed across the store, Copilot Dock, Keeper shared composer and chat primitives. TypeScript noEmit and diff-check passed. The persisted slash fixture also remounts the composer and verifies the next real submission retains the URL reference. Earlier PASS does not approve the expanded scope.

This is mocked HTTP/SSE and in-process DOM evidence. Actual layout pixels, screenshots, installation, provider runtime, formal approval, CI and merge are not established. Cached transcript authority, nonpersisted recovery and async media completion ownership and complete async voice/attachment diagnostics remain separate work for the full active goal.
