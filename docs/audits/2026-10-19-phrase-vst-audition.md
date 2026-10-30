# Phrase instrument selection and native audition

Issue #43879; Native Stack #43886, PRs #43884 and #43885. The destination is
`feat/music-phrase-arrangement`, the branch of PR #43878 in a different stack.
Publishing or merging this stack does not establish inclusion in main.

## Behavior

The phrase piano roll now uses the score viewer's existing instrument picker.
The first audio Space opens it; `i` stops playback and changes the instrument.
The picker supports a verified VST instrument, presets, its native editor, and
an explicit SoundFont choice. A failed VST does not select a fallback.
External MIDI output remains a separate explicit route.

Editable phrases are prepared by the existing worker as Standard MIDI Files,
then rendered by the installed native VST host. Imported MIDI retains channel,
controller and expression events. A selected asynchronous SMF2 pattern becomes
a synchronous performance file; SMPTE timing is converted without changing
elapsed time. The original imported source is preserved. Independent source
ports are refused rather than collapsed into one instrument's channel state.

Stop, edits and close cancel owned work and fence late playback. Successful
renders retain their WAV and performed MIDI outside temporary playback files.
The existing Lane observer receives local state and file hashes; it is not an
action receipt or a complete playback history.

## Execution observed on 2026-10-19

An isolated tmux terminal ran `viewer.mjs --sequence` from source head
`632e66166ad5ff22c979999325d0304a820f3eae` with separate project and state
directories. This preceded the later SMF2 WAV-export correction.

The audition entered a four-beat phrase at 100 BPM, with C3, G3 and C4 at beats
0, 1 and 2, each lasting one beat. Space opened the installed instrument catalog.
Searching Retrologue, selecting it and its default state started native rendering.
The host verified Retrologue 2.4.0 as a Steinberg MIDI instrument.

The native receipt recorded 149,940 stereo frames at 44,100 Hz, 3,400 ms including
the one-second release tail, and peak amplitude 0.31084585189819336.

| Retained file | Bytes | SHA-256 |
| --- | ---: | --- |
| WAV | 1199624 | `0aaf9555465536e616bfdce3514027d41ba9cb33055dcf708f84bde8fd7e7e39` |
| Performed MIDI | 101 | `5b392533bdf3dc7fb7708f6ffe7da668d0571cffee7cc6feac859187783883e7` |

Both retained files were rehashed and matched their native receipt. The actual
native player acknowledged playing, paused, playing again and finished, in that
order. `q` saved all three notes and ended the terminal session; the retained
files survived. Manual terminal captures and native snapshots are kept with the
local audition artifact. No screen-text assertion test was added.

Only the existing `native/MusicTransport.swift` helper was compiled with
`xcrun swiftc -O ... -framework AVFoundation -framework CoreAudio`; no Dune build
ran. Helper SHA-256:
`3e53c4cfc9110a5ee8ec7ecaef86ec9c1a0176afc88b2ab246836988ef123b81`.

## Focused checks and review response

At source head `304181fab9b9372e7a3fcb80666eaabe4c0821e9`:

```sh
cd tools/alphatex
node --test test/sequencer-vst.test.mjs test/vst.test.mjs \
  test/sequencer-worker.test.mjs test/sequencer-close.test.mjs \
  test/phrase-arrangement.test.mjs
```

31 tests passed, none failed or skipped. Coverage includes real worker SMF
preparation, selected SMF2 and SMPTE timing, selected-instrument requests,
cancellation, late completion, retention, player ownership and close. Controller
checks inspect requests, saved state and decisions, with owned IO substitutes.

Independent source review found one P2: `:wave` omitted the selected source
pattern. A response agent reproduced the failing export decision and passed
`editor.pattern`; the controller now checks that request. The reviewer then
reported PASS at `304181fab9b9372e7a3fcb80666eaabe4c0821e9`, scoped to source.

## Remaining evidence and scope

This was a direct JavaScript terminal launch with an existing installed VST host
and a separately compiled transport helper. It does not prove the installed
MASC TUI includes these changes, acoustic audibility, independent GitHub approval,
CI success, merge or the full rich-TUI objective. Source clip-loop reconstruction
and separate VST instances for independent source MIDI ports remain unfinished.
