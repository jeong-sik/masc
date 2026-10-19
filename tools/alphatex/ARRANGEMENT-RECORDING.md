# Record against an arrangement

Open an arrangement with `masc-alphatex --arrange` or reopen with `--project FILE`.
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

[Audio input monitoring](INPUT-MONITORING.md) is explicit: select an input and
`:monitor AUDIO_OUTPUT_UID`, or `:monitor off`. It also works before recording.
Recording waits for the standalone monitor to close and opens the selected monitor
inside the recorder's own input engine. After finalization, standalone monitoring
resumes while the view remains open. These ownership transfers can have a gap;
they are not gapless punch-in/out. MIDI input monitoring, count-in, measured
roundtrip latency/compensation, physical-device alignment and whole-arrangement
loop recording remain unfinished. No monitoring output is selected automatically. Native MIDI-only, WAV-only, mixed and hybrid arrangements publish their
host-clock epoch for recording admission; a pending transport change cannot admit
a new take before its acknowledgement.

An epoch request uses its own UUID and is evaluated by the native owner after
earlier transport commands. Older status responses cannot admit a recording.
Cancellation rejects that request without opening late inputs. Backing errors
continue to belong to the recording owner while the view is closing.

Captured controller/program state still follows the explicit baseline rules in
[source state](SOURCE-STATE.md). Complete original UMP is retained even when a
region cannot restore its unknown initial state; that case reports a diagnostic.
Recording does not invent controller defaults to bypass playback admission.
A recorded silent preamble can establish its source-defined values before the
first attack, at the original event timestamps. Repeats and seek retain that gap;
they do not send future controllers early. A baseline arriving after a dependent
attack or relative mutation remains insufficient.
