# Installed music capture and passage editing — 2026-10-23

The installed recorder saved simultaneous stereo audio and MIDI 2.0 input, and
the existing native MASC TUI opened the newly installed passage editor twice.
Saved files support the results below. These are separate executions with
separate runtime revisions; neither establishes physical USB interface latency,
audibility, screen layout, overall server health, or full sequencer completion.
The [receipt](../evidence/2026-10-23-music-capture/receipt.json) records exact
runtime identities, clocks, packet payloads, file hashes and measured values.
Raw WAV and private orchestration logs remain local; their hashes identify the
artifacts independently read for this report, rather than supplying those bytes
in this documentation PR.

## Simultaneous capture through the installed recorder

The recorder used CoreAudio's `BlackHole2ch_UID` and one owned CoreMIDI 2 virtual
source. A separate PCM producer sent a known stereo signal to that explicit
loopback output; no microphone or unrelated IAC source was selected. The actual
input was source `1776153139`, selected with `--midi=1776153139`. Recording required
`r`; `s` finalized it, `e` exported a MIDI 2.0 Clip, and `q` closed the owned view.
The source producer, tone output and recorder processes were closed afterwards.

| Observation | Saved-file evidence |
| --- | --- |
| WAV | IEEE float32, 48,000 Hz, stereo; 134,400 frames / 2.8 seconds |
| Audio block ledger | 28 contiguous 4,800-frame blocks, summing to the WAV frame count |
| MIDI | Eight two-word type-4 UMP messages, protocol 2, from one virtual source |
| Multitrack data | Three notes across group 0/channel 0 and group 1/channel 2; zero-based protocol coordinates |
| Raw preservation | Every UMP word and original host tick equals the corresponding sender receipt |
| Export | One Clip for that input source; all eight type-4 payloads equal the raw and sent words |
| Waveform data | Captured block extrema contain nonzero positive/negative values in both channels |
| Tone check | One second inside the acknowledged output: 440 Hz left amplitude 0.050000000153370305; 660 Hz right amplitude 0.039999999964751606 |

This execution used runtime
`8d405320bb713f07735dc78022313eb465b8a4ca13ab6c337d81ff6e1b3cfc67`.
An independent review reread the actual WAV, manifest, blocks, raw UMP, Clip,
sender receipts and binaries; it independently decoded the files and recomputed
the tone amplitudes with agreement within 1e-12.

The clock origins must remain explicit: WAV frame zero is `firstAudioHostTime`,
which was 35.41408333333333 ms after `requestedStart` in this take. Session-relative
note positions therefore differ from WAV-frame-zero positions by that amount.
The receipt includes both. Clip timing is quantized to 1000 PPQ; matching its
payloads does not prove preservation of original host timestamps in the Clip.
Those timestamps remain in the raw JSONL. The PCM producer reported zero
underrun frames; that is not a measurement of every recorder/device drop.

An earlier attempt supplied a negative source ID as a separate `--midi ID`
argument and failed argument parsing before opening inputs. The canonical
`--midi=ID` form was used for the successful take. A device-free `parseArgs`
probe separately confirmed acceptance of the negative equals form and refusal
of the split form. The successful take's ID was positive, so this report does
not claim an actual negative-ID input connection was exercised. The first
attempt's raw stderr was not retained; its failure summary and the independent
parser reproduction are the available evidence.

## Default installed passage stretch from the native parent

Stack #45341 landed through its top PR [#45340](https://github.com/jeong-sik/masc/pull/45340),
including core [#45339](https://github.com/jeong-sik/masc/pull/45339). The exact
installed runtime is
`e55030b649cd1fc9d3fdc59dea54a941635c55db62ef39faa161770377b8afb4`.
All 119 installer fingerprint inputs match the reviewed music source on main
`3ca07987a05ee18889caca38b70e874f68d5ddc0`; copied module bytes, the completion
marker, VST lock digest, shared-environment completion marker and launcher
reference were checked. This is not an independent dependency-environment rebuild.
The 23 native
inputs were unchanged from the preceding installation, so the seven native
helpers were reused only after byte/hash equality checks. No native compilation
or local Dune build was performed for this installation. The existing OCaml
`masc-tui` binary's hash was unchanged.

A private instance of that installed parent opened its default music child,
imported a two-track PPQ1001 source, selected channel 1 and its two notes, sent
`:stretch-notes 2`, `:undo`, `:redo`, then saved the project, exported MIDI and
exported track harmony. Closing the music view returned to the still-live parent.
Opening music again created a different child PID using the same new runtime.
`:open edited.json` reopened the saved source; stretching by `1/2` and saving /
exporting restored its original timings. Both owned children and the private
parent were then closed. No live server was replaced or restarted.

| Selected note | Original start / duration | After factor 2 | Reopened, factor 1/2 |
| --- | --- | --- | --- |
| C4 | 143 / 286 | 143 / 572 | 143 / 286 |
| E4 | 1001 / 286 | 1859 / 572 | 1001 / 286 |

These are integer source ticks. The selection origin stayed at 143. Original
source bytes, native note IDs, port/channel, velocity, release-message form,
controller, pitch bend, tempo and the other track were preserved. Each exported
SMF matches its saved editable document. Harmony's sounding spans are 143–715
and 1859–2431, matching the stretched notes. Independent intermediate snapshots
were not taken for each undo/redo request; the final saved state after those
requests is the measured result.

The library initially received the invalid `:project` command. It was corrected
to `:open` in the same live child, without restarting it. The original request
list is an attempt log, not a list of successful commands. The final reopened
inverse-edit files and the separate correction record support that later flow.
Private-parent HTTP refresh failures reflect its intentionally absent server;
the music-file results do not certify server health.

## Remaining verification

Physical USB/MIDI instruments, an external interface, acoustic timing and
subjective audition remain unverified by these executions. The synthetic
loopback and owned virtual source provide real OS input/output evidence for
this bounded configuration. See the [recording guide](../../tools/alphatex/README.md#recording-audio-and-midi)
for current take playback and route selection, and the
[stretch guide](music-selected-stretch-20261023.md) for editing semantics.
