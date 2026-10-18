# Native paired capture regions

The standalone `music-arrangement` helper accepts `capture-arrangement` schema 5
for paired WAV/UMP region transport. The JS `openPlayback` bridge recognizes this
format, checks the common host clock and pins native MIDI2 destination bindings.
The arrangement TUI's ordinary play command prepares captured and ordinary WAV
lanes through the IO worker. Choose `:midi-output MIDI_UID` and
`:mixed-output AUDIO_UID`, or `:midi-source ASSET SOURCE_ID MIDI_UID` for a
captured input override. `:play-audio` remains explicitly WAV-only.

A plan retains the existing `assets` and `regions` for WAV. Captured WAV regions
use [their rational source clock](CAPTURE-AUDIO-CLOCK.md). `umpRegions` contains
schemaVersion 1, the same duration, complete `sources` and compressed `regions`.
Each source has an asset `id`, canonical decimal tick `extent`, and its complete
original UMP `timeline` (schema 4, clock, bindings, packets and source duration).
Each MIDI region has `id`, `source`, `startSeconds`, canonical source-tick `offset`
and `extent`, and a positive integer `repeatCount`. Sources retain their original
packet/source identity; only the derived playback state addresses use the bound
physical destination UID.

Packet sorting and interval membership use original UInt64 tick differences.
The source's exclusive end may be one beyond UInt64.max; it is never added to the
absolute origin. State reconstruction takes an exact prefix ordinal rather than
converting the cut to floating seconds. Events at the entry tick establish
baselines and live keys in original order; the region end is exclusive. Original
controller, note attribute and release words are retained. Events due exactly at
entry remain an original-order batch, including zero-duration attack/release
pairs. A delayed boundary drains releases for already acquired FIFO instances
from its one active copy; missed Note Ons and skipped copies stay silent. Fully expired keys are
excluded when entering or reconciling a late callback. Integer/rational arithmetic
locates the current repeated copy without allocating its predecessors.

Project placement is quantized downward to the native integer-nanosecond clock;
source-relative deadlines round upward from their cumulative rational positions.
Each placement quantization is less than a nanosecond. Region period rounding
never accumulates across repeats. Audio remains on its source sample grid, and
this does not claim sample-perfect external MIDI or instrument-envelope seeking.

`UmpOutput` owns the pinned CoreMIDI client/port, uncertain keys, pedals and SysEx
acquisitions, and the physical mutation footprint. The full-source owner and
region scheduler use its effects with separate timer lifetimes. A region releases
only its physical channel scope; sequential assets on a channel share prior
mutations and restore explicit original baselines. Overlapping channel scopes
require independent routes. Scope includes replayed prefix state and keys that
began before the cut. Baseline coverage is checked against the plan's potential
mutations before output, including before each surviving Note On. Opaque effects,
unknown baseline dependencies and mixed state dialects report diagnostics; original
full-source audition remains available. No default controller values or lossy
protocol conversion are invented.

Staging releases owned notes but acquires no restored notes. All acquisition waits
for the audio owner's common future epoch. Late callbacks reconcile the current
phase instead of emitting skipped copies. The owner waits for every audio voice,
MIDI completion and the arrangement horizon; an empty or silent tail remains live.
Pause, seek, cancellation, endpoint loss and output errors preserve the same owned
cleanup and process-drain boundaries. A final helper close disposes the shared
port; an individual region boundary does not.

This follows the established distinction between [MIDI state chase at a new
position](https://www.steinberg.help/r/cubase-elements/15.0/en/cubase_nuendo/topics/playback/playback_chase_c.html)
and original sequential event delivery. Native event-list submission uses
[CoreMIDI's MIDI2 API](https://developer.apple.com/documentation/coremidi/midisendeventlist(_:_:_:)).
Arrangement SMF/UMP composition, monitored overdub,
latency compensation and physical/visible/acoustic proof remain separate work.


Project preparation owns one private root until its native player closes. Each
capture is verified and copied once with all four original parts; waveform and
UMP derive from those same immutable files. Repeats remain compressed. Binding
keys include asset and original input source ID, so two takes named by the same
input cannot accidentally share an override. A selected default MIDI output
applies to inputs without an explicit override; native admission still checks
physical group/channel ownership. Source IDs are in the captured source manifest.
A capture with no MIDI packets retains a clock-only region alongside paired
sources. When all audible captures have no MIDI, ordinary play uses the native
WAV clock without requiring a MIDI output. It never fabricates note messages.
Audible SMF and captured UMP in the same arrangement currently receive an explicit
composition diagnostic; no lanes are silently omitted. A muted SMF lane does not
prevent captured/WAV playback. Failed or cancelled preparation removes the whole
private root, and a late cancelled result cannot acquire a native player.
