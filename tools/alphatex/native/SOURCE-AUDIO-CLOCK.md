# Rendered source audio clock

`music-arrangement` plans can attach `sourceClock` to a WAV region whose PCM
was derived from an original MIDI performance. The saved musical document keeps
its MIDI source; this field belongs to a private playback plan.

```json
{"id":"phrase","asset":"render","startSeconds":0,"offsetFrames":0,"frameCount":19314,"repeat":2000000,"sourceClock":{"start":"0","end":"437956","denominator":"1000000"}}
```

`start` and `end` are nonnegative original source seconds expressed over the
shared positive `denominator`. They are canonical unsigned decimal integers
within native UInt128 arithmetic. The interval is half-open and positive.
The original PPQ tempo map or SMPTE division determines these fractions. PCM
duration and the renderer's rounded output length do not determine the clock.

At the actual WAV sample rate, `offsetFrames = ceil(start * rate / denominator)`
and `frameCount = ceil(end * rate / denominator) - offsetFrames`. Validation
checks both values and the actual WAV bounds. A cut may contain zero samples;
it then contributes silence for its original clock horizon. A zero-frame
ordinary WAV region remains invalid. Captured-host, pulse and source clocks
cannot simultaneously govern one region.

Finite playback computes each copy and sample phase from absolute source-rate
frame time. Repeats stay compressed, including far seeks. Samples before the
first selected PCM sample are silent, and refill spans stop at the copy's exact
boundary. The final horizon is rounded once after multiplying the original
period by the finite repeat count. Its native signed frame range is checked.

For an arrangement loop, `projectTick` retains placement in the original
`loop.ppq`/`loop.tempo` clock and must agree with `startSeconds`. The native loop
maps its absolute phase to the same source period and lead used by finite
playback. Source and project periods need not be whole sample counts. Practice
uses this same backing mapping after its count-in; it does not change source
trims or repeat intervals.

`source-audio-clock.mjs` projects an already selected MIDI performance's original
tempo map or SMPTE division into these fractions and sample bounds. This
protocol support is the native timing boundary for VST backing integration.
The arrangement TUI does not yet prepare VST-derived voices automatically.
Renderer event timestamp equivalence, parent-owned VST preparation, explicit
external routing and resource lease transfer remain integration work.

`node native/test-source-audio-clock.mjs` exercises actual plan validation and
production PCM refill without opening a device. Its independent rational-time
oracle covers fractional cuts, two rates, finite and arrangement loops,
two million compressed copies, empty sample cuts and far seeks. Existing
WAV/captured loop checks cover their respective unchanged source semantics.
