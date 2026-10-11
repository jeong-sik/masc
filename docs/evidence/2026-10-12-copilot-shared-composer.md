# Copilot uses the shared owned composer

Base: `b902c97ce7d271ec322fc11da917abac93e25f49` (#42416).

## Measured failures

Actual Dock DOM fixtures reproduced old text remaining after credential replacement and old Enter invoking send before the auth rerender. During the repair a recipient-switch fixture confirmed that rejecting the host send alone still erased the old draft; the ownership check must precede composer cleanup too. A route-switch fixture reproduced an old Overview context being submitted before a Connectors rerender. The first route fixture used an invalid work tab, failed typecheck, and is excluded from evidence; the corrected valid Connectors fixture also failed with the route guard absent and passed after restoration.

## Implementation

The private Dock textarea/buffer/submit path is removed. Shared ChatComposer provides credential-owned and per-Keeper drafts and structured input. A host ownership predicate checks the current credential epoch, selected Keeper and route snapshot before starter/send effects and before shared payload generation/draft cleanup. Keeper switches preserve each unsent text draft. Starter submission leaves independently authored drafts intact.

The existing block-to-attachment/display conversion is extracted unchanged into composer-message.ts, used by both Dock and Keeper panel. Dock forwards semantic user blocks, exact action identity and media/reference attachments into the common sending action with Copilot channel/context. A reference-only fixture uses the actual Dock controls, action, API/SSE decoder and request body, verifying the reference survives the wire and canonical input. Obsolete private composer CSS is removed from both stylesheets.

## Checks and limits

246 focused tests passed: Copilot, keeper-shared and chat primitives. TypeScript noEmit and diff-check passed. Initial independent hostile review of the full seven source/test/style files found no P0-P2.

This is mocked HTTP/SSE and in-process DOM evidence. Actual layout pixels, screenshots, installation, provider runtime, formal approval, CI and merge are not established. Cached transcript authority, nonpersisted/media recovery and complete async voice/attachment diagnostics remain separate work for the full active goal.
