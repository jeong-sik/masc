# Queue candidate in a populated fixture

This is a manual observation, not a PTY regression test or a production run.
On 2026-10-28 around 19:07–19:10 KST, a private workspace and the sibling
[read-only fixture](../fixture.py) supplied eight synthetic chat messages, one
running item, 18 waiting events and one scheduled item. Every POST returns
405; no real Keeper, credentials or production server was used.

The native executable came from `Minimal manual checks` run
[40667879437](https://github.com/jeong-sik/masc/actions/runs/40667879437),
scenario `detail-ownership`. Its receipt records source
`2732143dfeac5d8a33de2e7e4ac6b9042b328ff6`, workflow source
`5011a957ed6e8a3aa7b613ac51374cf2484e04ab`, macOS arm64 and binary SHA-256
`dccbd2fad3683b271f8beabd69df2412a1026bb1fefa2cbac5e35f0a209d3e19`.
The downloaded binary hash and its `--build-commit` agreed. The receipt
records three passing suites: `test_tui_detail_reading`,
`test_tui_board_successor` and `test_tui_usage_scope`; none exercises this
Queue panel. This observation does not establish the workflow's final
conclusion, installation or the behavior of the later local follow-up.

The executable ran on macOS arm64 with tmux 3.6a and `TERM=xterm-256color`,
with an isolated process environment and base path. The fixture is not a
matching MASC server binary, and the TUI displayed its generation mismatch.
`tmux capture-pane -p` recorded text rows; no human reaction times or physical
keyboard/IME behavior were measured.

Ctrl-T opened Queue. Two Down keys selected the first waiting event, `?` left
that selected frame unchanged, and Enter opened its detail. After returning,
`n` produced the fixture's HTTP 405 refusal in the panel. That demonstrates a
displayed refusal for this request; it does not demonstrate a successful
priority change, real server ordering, or current-turn interruption.

| Size | Box rows | Waiting events visible | Event rows truncated | Chat body visible |
| --- | ---: | ---: | ---: | --- |
| 80×24 | 21 | 10 of 18 | 10 | no |
| 100×24 | 21 | 10 of 18 | 0 | no |
| 120×36 | 33 | 18 of 18 | 0 | no |
| 160×40 | 37 | 18 of 18 | 0 | no |

These counts apply to this fixture and to this full-screen candidate, including
its current status and guidance rows. Truncation at 80 columns affected the
end of each visible event line. They do not compare interactive side and bottom
layouts or measure comprehension.

| Capture | SHA-256 |
| --- | --- |
| [Queue 80×24](queue-80x24.txt) | `b065ca35c7a54b8812909612d38fe464d129731e5a1dea761d1a6497bc372baa` |
| [Queue 100×24](queue-100x24.txt) | `9f3275d8b18d83f66b0f2cc1613d63f5974785283c1310fe449c47c8b5827204` |
| [Queue 120×36](queue-120x36.txt) | `dfae4afa9b3f3b75098f9aebafb9355902e1ace2df718f02e40cdef73ab9d8db` |
| [Queue 160×40](queue-160x40.txt) | `1b9ce249320fc2d6f3ccf291b73d098f55128379a52d57ddbbd1f40f2858d026` |
| [Selected event](queue-selected-80x24.txt) | `8fa8b00c7a7c23775696620ed6161cfad824251d778b9013af7aab77587fd331` |
| [After `?`](queue-after-question-80x24.txt) | `8fa8b00c7a7c23775696620ed6161cfad824251d778b9013af7aab77587fd331` |
| [Event detail](queue-detail-80x24.txt) | `3ad2a5e45afaa21f682fc1a9e79d638bb2eeff0e975ee3631c3e6137ea91a925` |
| [Read-only server refusal](queue-rejected-80x24.txt) | `c43aea93e6d31423965aacf3c9dae3d20c8f1f3bf4021dc4bf60e466ea6e7ce7` |
