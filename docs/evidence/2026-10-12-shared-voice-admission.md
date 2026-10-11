# Voice preparation belongs to the shared input draft

Base: `98756770108daad5b485f448e8bc6ddd7ea53c9b` (#42420).

## Measured failures

Two actual ChatComposer instances share the same credential/Keeper draft and use the actual voice hook. Deferred microphone acquisition reproduced two failures on the exact parent source: the other composer submitted authored text while microphone permission was pending, and both composers opened independent microphone requests for that one draft. Both fixtures pass after shared admission. Microphone/recorder boundaries are synthetic; this is in-process DOM evidence.

## Change

The immutable draft snapshot owns a voice preparation identity and typed acquiring/recording/transcribing phase. The voice hook admits that identity synchronously, publishes phase changes and settles it exactly once. The original identity accompanies transcription completion. A composer can only adopt that identity's result, and only its matching identity can release the shared pending state. All same-draft composers observe preparation status and retain input until it settles; another composer cannot start a second capture. Local composers keep a synchronous identity guard too. Full draft clearing refuses active file or voice preparation.

The transcript is adopted into the original shared draft before its preparation identity is released, retaining authored text. Existing mocked composer voice callbacks now explicitly simulate admission and settlement rather than injecting an impossible ownerless result.

## Verification and limits

354 focused tests passed across the actual shared composer/voice harness, voice lifecycle/HTTP, primitives, draft store, Keeper shared composer, Copilot and both Board consumers. TypeScript noEmit and diff-check passed. Positive full-flow coverage records microphone acquisition, recording stop, deferred transcription, unchanged text retained and completed voice submitted from the other composer. Permission failure clears preparation and preserves text. The full-flow fixture initially asserted before native Response JSON consumption finished; it now awaits the actual settled draft state. That fixture timing failure is excluded from product RED evidence. Only the original two failures were separately measured before repair.

Independent final review must be bound to the complete published scope. This does not establish actual microphone/network behavior, installed UI/screenshots, provider runtime, CI, formal approval or merge. Cancelled recording recovery, Board recipient-context ownership, complete attachment capacity/order reconciliation and the full streaming/interleaving/broadcast goal remain incomplete.
