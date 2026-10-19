# Captured-region WAV audition

In the arrangement editor, `:play-audio` selects an explicit audio-only audition
of audible WAV and capture lanes. `:output AUDIO_UID` selects its audio output.
Space then pauses/resumes, and `:seek BEAT` seeks the arrangement. Stop before
switching to another playback route. Audible standalone MIDI lanes must be muted
because this route does not synthesize them. Source packets remain in the project;
this command deliberately sends no MIDI. Regular play continues to diagnose
captured regions until paired region UMP output is connected.

A capture's region length comes from integer host ticks, independently of its WAV
length. If a .2-second region contains audio only at .1–.2 seconds, two copies
play at .1–.2 and .3–.4. They do not join the audio into a continuous .1–.3 span.
Subframe cuts with no complete source sample retain their silent interval.

Preparation verifies and privately copies every original capture part before
publishing its plan. The native `capture-audio-arrangement` plan (schema 4) has
ordinary WAV assets and compressed regions. A captured region additionally has
`captureClock` containing canonical decimal strings `origin`, `offset`, `extent`,
`firstAudioHostTime`, and integer Mach timebase `numer`, `denom`. Its frame offset
and count name the fully contained original source frames. No copied events,
repeated WAV files, rewritten samples or synthesized UMP enter the plan.

At source rate R, the native renderer computes the rational frame period from
`extent * numer * R / (denom * 1e9)`. The audio lead is the original audio host
origin relative to the region cut, plus its original frame offset. Each copy's
first output frame rounds its absolute rational start upward. The resulting
placement error is less than one source frame and does not accumulate across
copies. Source samples are copied unchanged; the renderer writes zeros in the
gaps. Checked 128-bit arithmetic preserves UInt64 origins and reports native
frame/clock overflow before opening playback. Binary search locates a repeated
copy after a far seek without expanding the repetition count.

Two reusable PCM buffers per voice bound decoded storage. Audio nodes share one
future host anchor. A separate owned horizon retains silent-only intervals and
tails, and is cancelled on pause, seek and stop. The owner waits for both the
horizon and final audio buffers before natural completion. The player node's
sample timeline resets on stop, as specified by [Apple's player scheduling
contract](https://developer.apple.com/documentation/avfaudio/avaudioplayernode).

The focused native check decodes the production WAV voice and compares original
stereo samples and silence across fractional cycle boundaries, edge refills,
far positions, two million compressed repeats and integer overflow. This is
separate from device capture, physical interfaces, acoustic output and visible
terminal verification. Paired UMP region reconstruction, overdub and monitoring
remain subsequent work.
