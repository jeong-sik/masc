# TUI retained output projection

Parent: `48a38add3816c8045c54a43450b014b09a9c35b0` (#41932).
Campaign: [#41857](https://github.com/jeong-sik/masc/issues/41857).

The TUI history reader skipped server image/voice blocks. A blank autonomous
assistant row was suppressed even when those blocks held completed output.
Failed request rows likewise retained their diagnostic text without projecting
these outputs onto the TUI surface.

`Masc_tui_chat_media` reuses the canonical server block codec. It preserves the
prose and voice transcript whitespace, displays media metadata without expanding
inline payloads into text, and selects the newest image in producer order.
Media-only autonomous turns retain a row. Server failures keep Error authorship
while carrying completed output. There is no new persisted row classifier.

`Masc_tui_image_requests` owns authenticated peer acquisition, retained artifact
identity/byte/digest verification, base64 decoding and PNG preparation. The main
TUI only captures the request and schedules it; its existing generation/view/
Keeper guard admits the completion. Decoding, remote curl and conversion run on
system threads. Image sources are typed once as inline data/SVG, authenticated
peer paths or HTTP URIs. Provider filenames do not become local file reads.
Existing Ctrl-O opens the selected output; existing input dismisses the image.
Voice duration/source/transcript is visible. Local voice playback remains owned
by the server (`lib/voice/voice_bridge.ml`); this change adds no client playback.

## Executed evidence

| Boundary | Command / artifact | Result |
| --- | --- | --- |
| Canonical codec through history and display projection | `test_tui_chat_media` / [media.log](media.log) | 5 scenarios passed |
| Existing history behavior | `test_tui_keeper_chat_history` / [history.log](history.log) | 76 passed |
| Existing typed image selection | `test_tui_image_preview` / [preview.log](preview.log) | 13 passed |
| Cache and converter policies | `test_tui_image_cache` / [cache.log](cache.log) | 29 passed |
| Final TUI and Dune fixture dependency closure | focused output-media alias / [terminal.json](terminal.json) | Completed execution receipt |
| New output interactions | inline PNG, peer PNG, image attachment URL, SVG, failed turn with image/voice, peer HTTP 503 | 6 real PTY interactions; [pty.log](pty.log) |
| Existing retained artifact interactions | success, HTTP refusal, cancelled request | [stored.log](stored.log); cancellation is a bounded negative observation |

The extracted graphics payloads in `*-display.png` decode as 8x8 red images.
PNG modes preserve the original bytes. SVG conversion produces the expected
frame. `*-history.txt` and `*.ansi` capture the TUI's actual retained frames;
[failure-history.txt](failure-history.txt) shows diagnostics, image metadata and
voice transcript together. These are local HTTP fixtures and terminal protocol
observations, not a physical terminal screenshot or a deployed service.

The previous TUI binary (#41915, same history/media source as #41932) failed to
show an image-only assistant row's output: [before-inline-final.txt](before-inline-final.txt)
and [before.log](before.log). The first fixture incorrectly represented
`autonomous_turn` as a boolean, so that reader classified it as direct; this
run proves missing direct image output, not autonomous row suppression. Final
fixtures use the canonical autonomous marker object. An intermediate attachment
fixture used `mime_type`; it was corrected to the codec's `mimeType` key. No
product decoder fallback was added to accommodate incorrect fixtures.

No full build, full CI, provider execution, installed binary, live transcript
mutation, deployment, independent GitHub approval or merge is claimed.
The complete Godfile campaign remains open; this is one bounded TUI repair.
