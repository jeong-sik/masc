# Voice and send admission before rerender

Actual native DOM mic-click followed by send-click before rerender reproduced premature transport admission in ComposerV2 broadcast and Board mobile mention. Each test used the real useVoiceInput hook and deferred getUserMedia: one microphone request was pending, but one message transport was invoked. Parent RED: /tmp/voice-sync-red-20261012.log.

Voice phase now lives in one reactive signal. The public readonly state getter reads its current phase, including through a voice object captured by an earlier event handler. Render reads subscribe to the same phase. Existing session IDs, resource ownership, authentication cancellation, exactly-once settlement and track cleanup remain the resource authority; no duplicate busy flag is introduced.

The inverse native send-click then mic-click also reproduced a microphone request after a deferred message request had already been admitted. RED: /tmp/voice-send-first-red-20261012.log. Both Board voice consumers use the existing onAdmitted callback to read their synchronous submitting/operatorActionBusy signals before requesting media. Rejection releases only that new attempted voice session.

Verification: six focused suites (Board voice-context-ownership, ComposerV2, BoardSurface, chat voice-input-lifecycle, voice-input, shared-voice-admission), 115 tests passed; TypeScript noEmit passed. The four new real-hook component fixtures cover both native event orders. The mic-first fixtures also unmount and resolve the late media request to verify tracks are released. The final mock-isolation and mode-transition fixtures passed the affected suite with 12 tests; final TypeScript noEmit passed.

Evidence is synthetic DOM with mocked permission/transport, not a physical browser microphone, installed TUI, provider runtime, screenshot, CI, merge or formal approval. Board auth/routing request ownership, unknown outcomes and the full provider chat goal remain outstanding.

Independent response review considered a missing desktop post voice guard. Source and a real-hook mode-transition fixture showed that mobile mic and desktop post controls are in mutually exclusive modes; switching to post cancels the voice session before post admission. The late stream is stopped without starting recording. The reviewer withdrew that HOLD; no extra global post gate was added.
