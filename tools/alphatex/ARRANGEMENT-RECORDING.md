# Record against an arrangement

Open an arrangement with `masc-alphatex --arrange` or `--arrange FILE`.
Select backing outputs as described in [arrangement playback](ARRANGEMENT.md).

1. `:inputs` discovers audio and MIDI input UIDs without opening an input stream.
2. `:input AUDIO_UID` selects an audio interface. `:midi-input all`,
   `:midi-input none`, or `:midi-input MIDI_UID` selects MIDI inputs.
3. Start backing playback with Space. `:record` opens simultaneous WAV and raw
   UMP capture against that playing epoch. Input selection changes apply to the
   next recording.
4. `:record-stop` finalizes the source, verifies all four captured parts in the
   arrangement IO worker, and adds a fresh captured lane and region. The backing
   continues. Undo removes that import and region together; redo restores them.

Pause, seek, output changes, source opening, saves and project edits first finish
the recording and attachment. Playback continues while the recorder flushes its
files. Closing the view also waits for that boundary before stopping backing and
saving. Cursor and selection changes can continue during recording. Input loss
or backing failure retains the take for recovery; it does not claim successful
attachment. A cancelled opening never opens late inputs.

The original take remains under the project directory's `recordings/UUID` even
after a successful content-addressed import. Failed imports retain that directory
and report it on stderr. `arrangement-recording.json` records the original project
path and epoch; successful attachment adds `alignment.json`. A portable Save As
owns the imported four parts independently. Original recording directories are
retained in their original location and are never removed by view cleanup.

The playback epoch and captured host timestamps share the system clock described
by [Apple AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime).
Absolute timestamps remain integer strings. Playback positions and tempo use the
exact binary64 values admitted by the scheduler, decoded to rational arithmetic.
The source begins at the next representable quarter-note project tick; the source
cut then rounds inward by less than one host tick. Thus at most one project tick
of leading material is excluded from the region, while the full source remains
retained. Startup pre-roll and material beyond the backing endpoint are retained
in the original source and excluded from the placed interval. Placement provenance
and the rational rounding error are stored on the captured asset.

This is capture against backing playback. Software input monitoring, count-in,
latency measurement/compensation, physical-device alignment and whole-arrangement
loop recording remain unfinished. No input is automatically routed back to an
output. Native MIDI-only, WAV-only, mixed and hybrid arrangements publish their
host-clock epoch for recording admission; a pending transport change cannot admit
a new take before its acknowledgement.
