# Voice capture has one admitted lifetime

Base: `80bd94886bdeb648620f75f30ef9dcfe62007525` (#42419).

## Measured failures

Actual useVoiceInput mounted in an in-process Preact harness with deferred browser microphone acquisition reproduced two failures on the parent product source: permission completion after unmount started the recorder, and two immediate starts before permission completion issued two microphone requests. Both exact scenarios pass after repair. MediaRecorder and microphone devices are synthetic boundaries; this does not establish real microphone/browser behavior.

## Change

A VoiceSession is registered synchronously before microphone acquisition, carrying admitted callbacks, host context predicate, credential epoch, controller and recorder/stream/chunks. Acquiring is a distinct phase. Late microphone acquisition releases its tracks when the original session is no longer current. Unmount and credential replacement detach recorder callbacks, stop tracks and abort transcription. WAV conversion and HTTP completion recheck that exact admitted session; callbacks cannot be retargeted to the latest render. Late cleanup cannot reset a newer active session's state. Track cleanup is in finally around recorder teardown.

The transcription HTTP boundary combines caller cancellation with a credential-change controller for acquisition and body consumption. Its arbitrary client wall-clock deadline and corresponding implementation-mirroring test are removed. ChatComposer supplies captured host ownership. The direct Board consumers distinguish acquiring from transcription in their activity vocabulary.

## Verification

342 focused tests passed across voice-input, the actual-hook lifecycle harness, chat primitives, Keeper shared composer, Copilot, Board composer and Board surface. TypeScript noEmit and diff-check passed. Added lifecycle coverage also verifies credential replacement during microphone acquisition, unmount aborting a live transcription request and suppressing a delayed response, and WAV completion after credential replacement producing no upload. Only the original two lifecycle cases were separately measured RED on parent source; do not count the other positive fixtures as before/after measurements.

Independent preliminary source review found no P0-P2; final complete scope must be bound to its head/base/diff after publication. This is focused in-process/mock network evidence, not real microphone, provider runtime, installed UI, screenshots, CI, formal approval or merge. Canonical cross-composer voice pending state, recording recovery, Board recipient-context ownership and the full streaming/interleaving/broadcast goal remain incomplete.
