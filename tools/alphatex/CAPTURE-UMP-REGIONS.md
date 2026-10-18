# Native paired capture regions

The standalone `music-arrangement` helper accepts `capture-arrangement` schema 5
for paired WAV/UMP region transport. The JS `openPlayback` bridge recognizes this
format, checks the common host clock and pins native MIDI2 destination bindings.
Automatic project preparation and the arrangement TUI's ordinary play command
still require their source/binding connection; `:play-audio` remains WAV-only.

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
Arrangement SMF/UMP composition, ordinary TUI preparation, monitored overdub,
latency compensation and physical/visible/acoustic proof remain separate work.
