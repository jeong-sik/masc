# Listen to an audio input

In the arrangement editor, use `:inputs` to discover audio input and monitor output
UIDs. Select `:input AUDIO_INPUT_UID`, then `:monitor AUDIO_OUTPUT_UID` to listen
through that output. `:monitor off` stops it. Monitoring can run while backing is
stopped or playing; it does not add a take or create recording files.

`:record` transfers input ownership after the standalone monitor closes. The
recorder opens its selected output inside the same AVAudioEngine that captures
WAV, so an additional input reader is unnecessary. After finalization/import,
standalone monitoring resumes. These close/open transitions can have a gap.
Changing the monitor output first finalizes a recording; changing the input during
recording selects the next input, leaving the admitted recording unchanged.
Closing the view waits for recording and monitor children to close.

The native owner acknowledges active monitoring only after engine start and route
validation. The editor shows its selected output and reported I/O latency.
Acknowledgements and recorded manifests retain the separate input/output
presentation latency values with `kind: device-reported`. Those values are not an
impulse/correlation measurement of hardware roundtrip latency and do not alter
recorded source timestamps or project placement. No compensation is inferred.

Different input/output devices use a process-private, nonpersistent CoreAudio
[Aggregate Device](https://support.apple.com/en-ie/HT202000). The selected output
supplies its clock; input drift correction is enabled. Channel maps select only
the requested input and output device channels. System defaults are untouched.
The owner validates engine identity, channel maps and device availability, and
destroys its private route on stop or failed start. A removed/changed route stops
monitoring with an error; the editor does not silently choose another output.

Use the intended monitor output for your instrument/interface. An audio interface
may also provide hardware direct monitoring; choose the route appropriate to your
setup to avoid hearing both paths. Software monitoring here is audio only.
MIDI input-to-instrument routing, measured roundtrip calibration/compensation,
count-in and gapless punch-in/out remain separate unfinished parts of the active
sequencer goal. See [Ableton's monitoring guide](https://help.ableton.com/hc/en-us/articles/360006569179-Monitoring-in-Ableton-Live-FAQ)
for the distinction between software and interface direct monitoring.
