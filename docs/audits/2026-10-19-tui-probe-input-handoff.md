# Hand early terminal input to the TUI without losing late replies

Source comparison base: `8ba2fdd8477dbd9707acf5257989f138debfdd10` (#43795).
Source/state boundaries only; no native startup or key-response measurement.

## As-Is / To-Be

The combined startup probe shared the real input reader with the eventual key
loop, but kept capturing until its requested replies completed, its existing
deadline elapsed or its byte cap was reached. Already-decided user replay did
not end that wait. The same decoder was handed over afterward, preserving bytes
but leaving an early key behind missing terminal answers.

Startup now ends when that decoder reports `Input_ready`, independently of
`Replies_ready`. `Awaiting_replies` alone continues the existing capture wait.
It hands over the same decoder and unread terminal buffer without finishing or
discarding partial input. The pre-existing 0.2-second no-input capture window
and byte cap are unchanged; this source change adds no timeout or retry.

Simply ending capture earlier would leave graphics and cell dimensions stuck at
their initial unknown values. Previously, the late publisher applied only one
complete palette. After the probe's byte filter completed, normal palette/theme
and cell-size replies were consumed without an observer, and graphics replies
had no capability consumer. Score launch also captured initial graphics/geometry.

An immutable current-reply observation now belongs to the original decoder.
Actual parsed replies replace that value only when the observation changes.
The reader publishes the current value once and then changed values, without
copying replay or palette arrays on every input byte. The reply owner survives
byte-filter completion while the normal input decoder continues to own bytes.
Its typed replies update the same owner. Palette collection retains requested
slots and first answers; graphics and geometry retain the first valid answer.
Actual subsequent theme notices update theme mode.

| Source boundary | Before | After |
| --- | --- | --- |
| Decided user replay with missing answers | Startup capture continues | Same reader/decoder hands input back |
| Additional startup capture reads after decided replay | Permitted until replies/deadline/cap | Zero |
| Physical terminal readers | One | One |
| No-input capture policy | Existing deadline/cap | Same policy |
| Reply owner after byte-filter completion | Discarded | Retained for typed normal-decoder replies |
| Late graphics and geometry | Initial consumer values retained | Current observations update existing consumers |
| Score launch | Captured initial capabilities | Reads current graphics and geometry |
| NO_COLOR / actual graphics refusal | Existing distinct states | Preserved |
| TUI input/paint latency | Not measured for this comparison | Not measured |

Zero is a source control-flow count after decided replay, not milliseconds,
first paint, server readiness or completed Keeper work. Main setup before/after
the probe, HTTP refresh, frame construction, prefix completion and filesystem or
backend work still have their existing costs. Retaining the observation owner
also retains its decoder buffers, and normal reply handling adds observation
publication work. Net CPU, memory and latency effects remain unmeasured.

## Consumers and ownership

Changed observations update the existing palette/theme store, graphics protocol,
image cell dimensions, portrait display choice and MSX protocol/geometry. Full
repaint is requested through the existing presenter path. The score callback
reads those current values at invocation; it still requires actual Kitty
support and positive measured cell dimensions. An early key cannot grant image
or score support by itself. Initial unknown/refused graphics keeps the existing
iTerm or unsupported fallback.

Completed byte filtering does not mean all optional replies have arrived.
Late ANSI slots, theme notices and cell-size reports pass through the normal
input decoder and reach their original observation owner. Query graphics are
checked by the existing exact query-reply parser. Duplicate/ignored replies do
not republish unchanged observations. Callback delivery is on the owning input
path, with no new worker, queue, timer or competing stdin reader.

## Authored evidence and limits

Three compound cases are authored but unexecuted. One hands off on the first
UTF-8 byte, continues a split OSC through the same probe, preserves opaque
bracketed-paste contents and a later PageDown, and checks actual late replies.
Another uses the normal input decoder and real reader reply consumer after
probe completion, retaining immutable prior palette/geometry and keeping a
second reader untouched. It includes late ANSI, cell size, theme changes and
duplicate/first-answer handling. The third combines NO_COLOR early input,
actual graphics refusal and independent late geometry/theme observations.

These inspect byte/protocol/observation state, not terminal screen wording,
layout, row order, snapshots or PTY output. They do not execute startup's real
stdin effect or prove the main callback painted a frame. Parser and
diff/changelog checks do not prove typing, assertions, independent approval,
merge, installation, native key response or speed. No local tests, Dune, CI,
native/model run, installation or restart is performed.

A later matched comparison must keep binary/source identity, terminal behavior,
the same input and reply byte sequence, workspace and backend fixed. Record
probe start/handoff, decoded input application, capability application and
actual paint separately. Include silent/refused terminals, split and late
answers, failures, interruptions and unfinished outcomes alongside successes.
