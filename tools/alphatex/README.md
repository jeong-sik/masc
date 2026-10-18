# alphaTex in the terminal

The full score view uses the pinned official alphaTab 1.8.4 importer,
alphaSkia 3.5.147 engraver, MIDI generator and AlphaSynth synthesizer. MASC does not translate
notation into its own reduced score model. Bravura is loaded explicitly for
music glyphs; alphaTab's own Skia backend draws the terminal's PNG. Only the
selected system is rasterized in the interactive view, preserving official
fragment positions without allocating a whole-song image.

Install Node.js 22+ and pnpm, then run `scripts/install-alphatex.sh` from the
repository. This installs `masc-alphatex` beside the MASC commands and its
runtime files under the adjacent `share/masc/alphatex/<source digest>` directory.
Installation validates the native backend before atomically replacing the
launcher; an existing score view retains its own immutable runtime. The helper
must be on the TUI's PATH. For development, run `pnpm install --frozen-lockfile`
here and put this directory on PATH; `masc-alphatex` is the launcher.

In Keeper chat, `/score` opens the latest closed `alphatex` or `atex` fence in
the loaded conversation. `/score 2` opens the preceding score. This freezes
the source before transferring terminal ownership and returns to the same
conversation on exit. No source is sent to a browser or external service.

The full view currently requires a terminal supporting Kitty graphics with
measured cell dimensions: Ghostty, Kitty or WezTerm. The chat's ASCII preview
remains available on other terminals. In the score view:

- Up/Down or j/k scroll; PageUp/PageDown move a viewport and continue across
  systems; `[`/`]` select a system; Home/End jump to the start/end of the score.
- +/- change notation size; `t` cycles all tracks and individual tracks.
- Left/Right select a frozen score from the current conversation snapshot.
- Space synthesizes and plays the selected tracks, then pauses/resumes.
- `r` opens audio/MIDI input selection and the recording timeline on macOS.
- `v` shows the source and complete official diagnostics; `s` stops playback;
  `q` or Escape returns to the conversation.

Audio is synthesized to a private temporary PCM WAV by the official engine,
including its repeat order, instrument changes and note effects. It uses
the existing `[tui] midi_soundfont` when configured, otherwise the alphaTab
package's Sonivox SoundFont. Playback uses afplay, ffplay, aplay or SoX play
from PATH, in that order. A player failure is reported in the view. Playback
stops when the view closes. There is no synchronized playback cursor yet.
Track selection isolates sounding parts while preserving the full score's
pickup/grace timing, repeats and tempo. Parts explicitly sharing a MIDI channel
(such as percussion on channel 9) retain the official shared channel program,
volume and controller state; solo does not create independent MIDI channels.

Malformed alphaTex remains malformed: diagnostics and the original source
are retained. In particular, `\staff {score tabs}` uses **tabs**, not `tab`.
Support is defined by this pinned engine version, including its own limits
and defects; a passing fixture set is not proof of every possible notation.

To validate or export a file without a terminal:

```sh
node viewer.mjs example.atex --check
node viewer.mjs example.atex --render score.png --audio score.wav
pnpm test
```

Exports refuse to overwrite an existing file. Rendering and synthesis in the
interactive view run on workers. Only the active generation may replace the
score or start audio, and workers stop before temporary files are removed.

## Recording audio and MIDI

On macOS, the installer compiles a CoreAudio/CoreMIDI companion using the Xcode
command-line tools. In a score view press `r`, or run `masc-alphatex --record`.
Device discovery does not capture audio. Choose the audio input with `i` and
the MIDI sources with `m`, then press `r` to begin a new take. `s` stops and saves;
leaving the view also waits for file finalization. Recording never starts merely
because the score view opens. The input may be a connected audio interface,
built-in microphone, aggregate device or loopback device exposed by CoreAudio.

The take folder is displayed before recording. Its default is `music-sessions`
under the process's working directory; `--session-root /path/to/folder` chooses
another location. Every take has its own directory and no saved take is replaced.
`--input DEVICE_UID` and `--midi all|none|SOURCE_ID` preselect inputs from
`--devices`; the recording still requires pressing `r`.
WAV channel waveforms and MIDI source/group/channel tracks share the native host
clock. Waveforms show captured block extrema, not an editable sample waveform.
Use arrows to scroll tracks or time, +/- to zoom, and `f` to follow incoming data.
Space plays/stops the saved WAV through the system default output. It does not
play the captured MIDI tracks. Open an existing take with:

```sh
masc-alphatex --devices
masc-alphatex --session /path/to/take-directory
```

Press `e` after saving to export one MIDI 2.0 Clip per input source. UMP group and
channel data, 16-bit velocity and 32-bit controllers remain intact. Clip times
are quantized to 1000 ticks per quarter note; original timestamps and every UMP
word remain in `midi.ump.jsonl`. Clip-owned timing/start/end utility messages are
not duplicated in the export. Capture failures remain visible and retain their
files. See the [native protocol](native/README.md) for clock and failure semantics.

This recording view captures simultaneous tracks in a take. Overdubbing,
multi-take arrangement/mixing, MIDI playback/output, input monitoring, output
device selection and practice scoring are not implemented here. The existing
score playback remains available when returning to the score view.

alphaTab is MPL-2.0, Bravura is OFL-1.1, alphaSkia is BSD-3-Clause. Their notices ship
with the locked dependencies. The Sonivox license is in alphaTab's
`dist/soundfont/LICENSE` and must remain with a redistributed installation.
JZZ and JZZ MIDI SMF are MIT-licensed; their notices ship with the pinned packages.
