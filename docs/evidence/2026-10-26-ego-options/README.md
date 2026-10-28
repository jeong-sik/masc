# Native Ego options: SDK evidence and UI limit

Captured on 2026-10-26 with installed Ego 0.6.1.11 and skill guide v2.1.0,
in continuing owned Space **32**, Page `p1`, against owned local HTTP fixtures.
The production workflow JavaScript SHA-256 is
`788d22efc9cfab3d84faea133f7c6a0becde9097f768b1dbeaca17091c89f6b6`.
The source is unchanged between the option implementation and frozen schema-fix
candidate `c530c671ce160996d216af172896d3f15a6715eb`.

## What executed

[`options-proof.json`](options-proof.json) records 22 native option/selection
steps and five coordinate-input/state-wait steps. They include native
navigation/load options, fill without clearing, delayed key input,
label/index/string/mixed-array/null selections (including a disabled option),
pointer positions/labels, trusted right-click/double-click/drop, coordinate
move/click, wheel scrolling and relative browser POST exactly once.
`clearFirst:false` preserves the current insertion point; it does not promise
append-at-end. The captured fixture inserted before its initial `seed` text.
The source uses native SDK operations, without DOM event synthesis.

This primitive probe's captured requests omit the adapter's `tabId` routing
field. They are direct inputs to the production JavaScript function, not a
claim that those raw objects were accepted through the MASC tool. The committed
probe supplies that routing field for a future end-to-end codec check; that
small fixture change has not been rerun while the user holds Space 32.

The current source also executed the rich-input and Page-code fixtures. The
actual standalone OCaml codec decoded
[`rich-input-proof.json`](rich-input-proof.json) success against its exact
request, and [`page-code-proof.json`](page-code-proof.json) success, CORS failure
and predicate timeout against their exact requests. Those checks do not run
the full OCaml Peer or a real Keeper.

[`native-options.png`](native-options.png) is a native Page screenshot, inspected
after capture. It proves the rendered fixture result, not that a person saw
the page window or native cursor move.

## User-visible state remains unresolved

The operator reports that Space 32 and its result page do not appear in the
Ego UI. A user-provided Task Manager image shows the fixture tab inside Ego;
that private screenshot is not included here. Native `Page.bringToFront` and
`TaskSpace.handOff()` returned successfully, and the next SDK inventory showed
`agentDelegatedToUser`. The operator still reports no visible page. No further
Page input was sent after handoff, and no takeover or additional Space was used
to bypass user control.

The public [Space guide](https://lite.ego.app/document/en/docs/space) describes
the default Space model as using the same browser process rather than headless
or offscreen rendering. [Quick start](https://lite.ego.app/document/en/docs/quick-start#watch-and-take-over)
describes selecting a Space through the top-right Space management panel.
Those product descriptions do not prove that the local UI is working.

The earlier loss of Spaces 24/27 has no locally proven deletion actor. The
operator first reported not closing them and later reported one termination
without assigning it to either loss. An official-repository
[reply about lifetime](https://github.com/citrolabs/ego-lite/issues/496#issuecomment-6291041032)
documents 30-minute idle auto-close for agent-created, unpinned, still-agent-owned
Spaces, with different rules for user-owned, pinned, handed-off and completed
Spaces. This is relevant context, not proof of either local deletion. The user
has now authorized recreating a missing Space within this Goal.

## Component and candidate checks

[`activity-compile-proof.json`](activity-compile-proof.json) uses the actual
full operation declaration and actual TUI match fragment, with unrelated field
types supplied separately. It reproduces the incomplete repair's warning 8
and passes after covering every operation. It supersedes an earlier simplified
type-fragment check and is not full TUI typing.

[`schema-loader-proof.json`](schema-loader-proof.json) compiles the production
tool-definition loader ML/MLI unchanged, supplying only its domain record
container. It reproduces the integer-bound failure and loads the corrected
TOML, emitting four `Yojson.Float 0.0` bounds. It is not full server boot.

Minimal manual checks run
[40311954806](https://github.com/jeong-sik/masc/actions/runs/40311954806), workflow
ref `ci/ego-browser-proof-20261026`, workflow SHA
`7e6237ff2aaa0e192fa44ca1f7c9e140180d52b1`, candidate
`c9bf6f87ffb2c012f25c67793f2275176087bcfb`, concluded **failure**: compilation
reached behavior execution, where the tool-definition loader rejected the
number-option integer bounds. Some suites passed; the scenario did not pass.
The corrected candidate `c530c671ce160996d216af172896d3f15a6715eb` was submitted
to the same workflow as run
[40313912338](https://github.com/jeong-sik/masc/actions/runs/40313912338).
That run concluded **failure** at the stale TUI BiDi-only drag assertion after
the four executable builds and six preceding suites passed. PR #46141 replaces
the footer-text assertion with typed BiDi/Ego capability and request decisions.

The repaired parent candidate `c2c04d0aa651bd9feb2f377c6a8db7deefdcbc32` passed
**Minimal manual checks**, run
[40317334445](https://github.com/jeong-sik/masc/actions/runs/40317334445), workflow
ref `main`, workflow SHA `68814a433b691da990e449cba0c28e619c51b7c1`, scenario
`browser-lane`. This is the focused scenario's result, not all regression tests
or proof for the later Page observation extension.

[`page-observations-component-proof.json`](page-observations-component-proof.json)
records the later URL/title/info/snapshot/events/timeout extension separately.
The production workflow codec, emitter and receipt decoder compile as-is
standalone with only namespace aliases and pass seven actual OCaml test cases.
Thirty Node fixture tests exercise the emitted JavaScript, including consumed
event-buffer uncertainty, malformed observation values and dialog stops. The
current production tool-definition loader accepts the extended schema. File
hashes bind these checks to their sources. None of these fixtures execute the
new calls in real Ego or through an installed Keeper.

There is no installed-MASC, real-Keeper, operator-visible motion or full Goal
completion claim. Unsupported SDK and Space lifecycle work remains in the
[coverage inventory](../../guides/ego-sdk-coverage.md).
