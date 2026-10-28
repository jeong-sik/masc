# Isolated TUI layer and key observations, 2026-10-28

These are manual observations, not a TUI layout or PTY regression test. The
frames contain synthetic, unavailable workspace data; no user's conversation,
Keeper state, token, or production server was used.

## Provenance

- macOS 26.6.1 arm64, tmux 3.6a, `TERM=xterm-256color`.
- A copy of `~/.local/bin/masc-tui` reported build commit
  `ce29779050f54bc8a6d1bafd0b67d03230a1f344`; both files had SHA-256
  `43b664337c707e3a72affb75feb862bb615814331f8a61ff1e37e52f67a1b630`.
  That commit is the installed baseline, not the queue PR's candidate.
- The copied executable ran in a private workspace with only a `[tui]` config
  (`opening = "overview"`, `hints_visible = false`, `help_hint_shown = true`,
  `reduce_motion = true`). Environment credentials were not passed. A loopback
  fixture returned HTTP 503 for every GET and 405 for every POST; the copy had
  no sibling server binary and its PATH contained no `masc`.
- `tmux capture-pane -p` retained plain terminal rows. No screenshots or raw
  byte streams are claimed. The captures below were written on 2026-10-28
  between 18:00:43 and 18:01:40 Asia/Seoul; input time was not instrumented.

## Observed sequence

At 100 columns × 24 rows, `;` opened Agenda. Its footer advertised `?:help`,
but a subsequent `?` left the captured screen unchanged. Then Esc closed Agenda,
`@` opened Answering, `?` opened Help, and Esc restored the captured Answering
screen byte-for-byte. The fixture had no loaded entries; this does not prove
selection or scroll preservation for a populated panel.

The Agenda was also captured after resizing to 80×24, 120×36 and 160×40. Its
bordered area occupied 21, 33 and 37 terminal rows respectively, leaving the
navigation strip, footer and composer/status row. This measures frame geometry,
not information comprehension or a speed improvement.

| Capture | SHA-256 |
| --- | --- |
| [Agenda](agenda-before.txt) | `7882783bd91b90b88f502479cffd221e550db4155e2b1587dd68ebe0c5b1da93` |
| [Agenda after `?`](agenda-after-question.txt) | `7882783bd91b90b88f502479cffd221e550db4155e2b1587dd68ebe0c5b1da93` |
| [Answering](answering-before.txt) | `b61b4575616b07ebc0725e6d7597910a1c919537175a3e8d3b9e1b9a971303eb` |
| [Help over Answering](answering-help.txt) | `f3c3cb2a65182c9736b1bd4ce8dbde3f468de4c00d4f7467569e4a35f00a83b5` |
| [Answering after Esc](answering-restored.txt) | `b61b4575616b07ebc0725e6d7597910a1c919537175a3e8d3b9e1b9a971303eb` |
| [Agenda 80×24](agenda-80x24.txt) | `63e8571d6eff0d4285c0edcec46ba493eaf6141dd0962415aca161effa30dc1d` |
| [Agenda 120×36](agenda-120x36.txt) | `9fb96d0065215a54f2b826dfc7bad6e6a0f85e559ed3e67284b971ad98a1184d` |
| [Agenda 160×40](agenda-160x40.txt) | `898fcd0fce0e28192de2dba4cd4c8b60836c8a034526a789aa41f37c402c9586` |

## Help over an isolated chat

At 18:11:51–18:11:54 KST the same baseline binary ran at 100×24 in a second
private workspace with one synthetic Keeper declaration and `opening =
"keeper"`. Its loopback fixture answered `/health` with that workspace's
canonical paths and returned 503 for other GETs and 405 for POSTs. No Keeper
was started; chat history and live data were unavailable.

With an empty chat draft, `?` opened Help. Typing the single two-set jamo `ㅓ`
left the capture unchanged; typing Latin `j` immediately afterward scrolled
Help from lines 1–16 to 2–17. The input was sent as UTF-8 through tmux, so
this observes the resulting character, not a physical keyboard or every IME.

| Capture | SHA-256 |
| --- | --- |
| [Chat before Help](chat-before.txt) | `96727abdff59631d701116e7d7bcac3ef0f8eb02f0e59a9c10305dbfb204bb9d` |
| [Help over chat](help-over-chat-before.txt) | `e2cab017a3800de2a18f7a883f61e4ec5f31e45bc981f8ba9d36ed49965d5e5e` |
| [After `ㅓ`](help-over-chat-hangul.txt) | `e2cab017a3800de2a18f7a883f61e4ec5f31e45bc981f8ba9d36ed49965d5e5e` |
| [After `j`](help-over-chat-latin.txt) | `91d68e2b5c7622818cd6fcd76964487a0ec8e4236bb26c0b783510e05dc7d2eb` |

At 18:15:13–18:15:14 KST, `/about` opened the About frame in the same chat.
The footer advertised `?:help`, but `?` left the frame unchanged. Both
[before](about-before.txt) and [after](about-after-question.txt) have SHA-256
`83d04ceae8f74b7b0ac9b9eaa4f727d29c8f8b44241ad43bd44fd41a419ac1fa`.
This is an additional observed inconsistency; no About repair is claimed.

The separately generated [synthetic layer sketches](prototype/README.md)
compare row visibility and truncation; they are not captures of this binary.
The [populated fixture](populated-fixture/README.md) was prepared for a later
candidate comparison and observed only with the baseline executable so far.

## Parent candidate build failure

The artifact for [`Minimal manual checks` run 40659791104](https://github.com/jeong-sik/masc/actions/runs/40659791104)
was downloaded once at a work boundary. Its workflow was dispatched from
`main` at `ce29779050f54bc8a6d1bafd0b67d03230a1f344`, with native source
`a3c351925b09341d5051b0dc3a0a35d3508fa1c8` and scenario
`detail-ownership`. The artifact contained `build.log` and target list, but
no candidate executable or manifest. The build log reports two fatal warning 4
diagnostics in the Queue receipt match. This is not a successful candidate
build or a visible-UI result; the workflow's final conclusion was not read in
this observation.

The [excerpt](parent-build-failure-excerpt.txt) reproduces lines 42–60 of the
downloaded build log. Its SHA-256 is
`53c307e0ac92067d03f3fbb1201908df5de06208adbe721a210a9f9f709504cd`;
the original log's is
`477b0f60d7895072e9a8125777c4c6db70273573246e4ed4a2195bd383c37082`.
The local repair enumerates the receipt constructors; a focused OCaml 5.5.1
compiler probe of the extracted match passed with `-w +4+32+69 -warn-error
+a`. This is not a complete TUI compilation.

## Limits

This is one local operator observation under a deliberately unavailable
server, not a population study, an online latency measurement, a queue-panel
run, a candidate-build check, or a deployed-runtime verification. Timed sleeps
allowed redraw before capture; they are not measured reaction times. A useful
comparison of alternative layouts needs populated, identity-matched queue and
chat data and the same terminal sizes, followed by actual operator evaluation.
