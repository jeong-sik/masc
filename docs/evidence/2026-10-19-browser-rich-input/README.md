# Native browser input evidence — 2026-10-19

The candidate's actual Lane, keyboard domain, interaction parser, Stagehand
executor, wire and feedback scripts drove an isolated Chromium process and fresh
profile against `test/fixtures/browser-native-input.html`. The installed
Stagehand runtime bundle answered real native-input calls. The standalone bridge
uses a JSON callback for the unchanged session transport; this is not a full
MASC server build, installed binary check or production browser result.

`source-manifest.json` records the candidate inputs. Each listed file was
byte-identical between the compiled bridge source and the recorded source head.

| Scenario | Observed result |
| --- | --- |
| Semantic double click | One `dblclick` event, `isTrusted=true` |
| Focus then native Unicode text | Exact `안녕 Pele 🦊`, trusted input events |
| Meta+A then replacement | Exact `바꿈`, trusted modifier/key events |
| Stale document ID | `scene_document_changed` before `page.type`; previous text retained |
| Visible actor feedback | Screenshot retains the attributed actor and pointer; stale attempt says Not performed |

[Structured result](chrome-result.json) includes runtime methods and browser
observations. [Screenshot](chrome-native-input.png) is the final fixture state.
The runtime bundle's marker reports its own server/protocol versions in the
result; these are distinct from its installed package directory version.

Actual Backend tests with injected typed call outcomes separately checked
quarantine after uncertain keyboard dispatch, cancellation, known-unsent
failures, status and explicit close. This does not claim live Chrome fault
injection or that Stagehand sent native key-up after a failure. Quarantine keeps
pages and refuses further work until explicit recovery. Printable Unicode text
is supported; C0/DEL controls require explicit key actions. Stagehand rejects
supplementary-plane `press_key` before input and directs callers to `type_text`.

No local Dune/full build, CI cycle, installation, production restart or live TUI
validation was performed for this evidence.
