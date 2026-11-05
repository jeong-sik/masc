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
| Final TUI executable | `dune build bin/masc_tui.exe` / [checks.json](checks.json) | exit 0 |

No full build, full CI, provider execution, installed binary, live transcript
mutation, deployment, independent GitHub approval or merge is claimed.
The complete Godfile campaign remains open; this is one bounded TUI repair.
