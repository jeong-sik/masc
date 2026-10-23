# An eight-bar phrase and arrangement experiment

Start an empty arrangement with `masc-alphatex --arrange`, then use `:phrase`
to open its piano roll. Commands below include the leading `:` as typed in the
TUI. Save the parent arrangement before creating children so its `phrases/`
directory belongs to the chosen project folder.

Use `:tempo 96` in both the parent and each new phrase. `:bars 8` makes each
phrase 32 quarter-note beats in 4/4. Each chord below occupies one bar:

```text
:title Keys - close and drop2
:bars 8
:rename Keys
:program 4
:level 68
:pan 54
:progression 0 4 close Dm7 G7 Cmaj7 Am7 Dm7 G7 Cmaj7 Cmaj7
```

Save this close-voiced draft, then change the existing notes:

```text
:revoice-led 0 32 drop2 C3 C5 Dm7 G7 Cmaj7 Am7 Dm7 G7 Cmaj7 Cmaj7
:undo
:redo
:harmony track
```

Revoicing preserves note IDs, attacks, durations and velocities. Undo compares
the original chord spacing; redo restores the drop-2 path. Harmony reports
candidates for the sounding key sets: for example, the first inversion may
offer both `F6` and `Dm7/F`. These labels are alternatives, not a chosen harmonic
analysis. The final repeated Cmaj7 can occupy one continuous analysis span.
After analysis completes, `:harmony-export /absolute/path/keys-harmony.json`
saves all rows. Esc returns to the piano roll.

Choose `:soundfont-fluid` to bind the bundled SF2 and installed FluidSynth
engine. Wait for selection to finish before saving: saving does not wait for a
pending sound selection and can retain the earlier sound state. Stop, route
changes, reselection and close can cancel an unfinished capture. Then save the phrase, use
`:export /absolute/path/keys.mid` and `:wave /absolute/path/keys.wav`, and return
to the arrangement with `q`. The stored font and engine identity travel with
the editable draft. See [SoundFont requirements and timing](README.md#bound-fluidsynth-soundfont-audition).

Place the new asset at beat zero with `:place asset-1 0` and name its lane
`:lane-name Keys`. Asset IDs in this example assume a new empty parent; use the
actual library IDs in an existing project.

## Add independent bass and drum parts

Open another `:phrase`. Mute its unused first track before adding Bass; that
keeps the new part on its own MIDI channel without sending the empty track's
program/volume/pan setup.

```text
:title Bass - walking roots
:tempo 96
:bars 8
:mute
:track-add Bass
:program 33
:level 88
:note D2 0 3/4 92
:note A2 1 3/4 80
:note C3 2 3/4 80
:note E3 3 3/4 80
```

Continue quarter-note notes through the remaining bars, following G, C, A,
D, G, C, C roots. Keep each note shorter than a beat to leave a release gap.
Bind the SoundFont, save/export, and return. Add a separate parent lane with
`:lane-add midi Bass`, select it with `:lane 2`, then place this new asset at zero.

For drums, open a third phrase and use:

```text
:title Drums - backbeat
:tempo 96
:bars 8
:mute
:drum-track Drums
:program 0
:level 66
:note 36 0 1/8 100
:note 38 1 1/8 88
:note 42 0 1/8 62
:note 42 0.5 1/8 48
```

Repeat kick on beats 0/2, snare on 1/3 and closed hi-hat every half beat in
each bar. `:drum-track` uses General MIDI channel 10. Save/export with the bound
SoundFont, return, add/select a Drums lane and place the new asset at zero.

The parent now owns three independent MIDI assets and regions, each retaining
its phrase draft. `:edit-midi ASSET_ID` reopens a part for another voicing or
rhythm experiment; returning imports a new variant without replacing existing
regions. Select placement deliberately to avoid doubling the old part.

Select an available audio output using `masc-alphatex --devices` and
`:output AUDIO_UID`. Space prepares the stored sounds and plays them together.
`:export /absolute/path/eight-bar-lab.mid` saves the complete arrangement;
`:wave /absolute/path/eight-bar-lab.wav` renders a standalone mix. Each 32-beat
part lasts 20 seconds at 96 BPM. The authored source horizon ends the WAV;
extend the phrase or shorten its final gate when a longer release tail is wanted.

Save and reopen the parent with `masc-alphatex --project /absolute/path/arrangement.json`.
This recipe exercises composition, voicing comparison, candidate analysis,
independent lanes, stored instruments and export. Physical input latency,
external MIDI synchronization and audio/MIDI sample alignment require their own
device measurements.
