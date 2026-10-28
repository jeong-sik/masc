# Synthetic queue priority observation for source 234b647

This manual observation used the macOS arm64 TUI built from
`234b647137d3ce4cf352717fc58e2bc03855fcf2` by
[Minimal manual checks #40692580048](https://github.com/jeong-sik/masc/actions/runs/40692580048).
The downloaded executable SHA-256 was
`0767ca955e5c9b39b0b057a64a53658e75a07829fad100379426252fb238400b`;
its receipt and `--build-commit` agreed on the source. This is an earlier
candidate, not the later Help or notice fixes.

On 2026-10-28 between 22:30 and 22:36 KST, the TUI ran in a private 100×30 tmux session
with `TERM=xterm-256color`, an empty home and an isolated workspace. The
[loopback fixture](fixture.py), adapted from the read-only fixture, served
three fabricated queued messages and accepted only the two synthetic priority
POSTs; it denied other writes. It did not run a Keeper, use credentials or
contact a production server. The saved fixture differs from the one executed
only in its corrected docstring. The tmux server and fixture process were
stopped after the observation.

After opening Queue with Ctrl-T, Down selected `fixture-a` and another Down
selected `fixture-b`. Pressing `n` sent the synthetic run-next request for
`fixture-b` with `interrupt_token: null`, and the fixture returned the order
`fixture-b, fixture-a, fixture-c`. Pressing `l` sent move-to-end for the same
ID and the fixture returned `fixture-a, fixture-c, fixture-b`; a second `n`
returned `fixture-b` to the front. The captures show the resulting selection,
receipt and list after the final `n` and after `l`; the request log contains
all three synthetic mutations. Trailing spaces were removed from the captures.

The fixture decides its own responses and ordering. This demonstrates the
candidate TUI's interaction with that fixture, not a successful mutation on a
real MASC server, actual turn scheduling, or behavior of the later candidate.
The earlier screen also says priority waits for the current turn; later source
review found that a turn may yield at a safe boundary, and the subsequent
source uses non-interruption wording instead.

| File | SHA-256 |
| --- | --- |
| [fixture.py](fixture.py) | `311cd7bf70d3aebff6688327a25be1b5c41a3bb49745e3467e976723ba461fab` |
| [after-next.txt](after-next.txt) | `a65297d76eaf2f390829141529e6845fbe3ebb4e151e99e06199be6209b1ab13` |
| [after-last.txt](after-last.txt) | `77f6d14f2a9923fd0c390b6fa5342a95b40b3ffd668e1d56dcc0c42d79eae00c` |
| [synthetic-requests.jsonl](synthetic-requests.jsonl) | `87ff9529f365dece86644169c0545ea80040c3741e3a7094dfaf63538b7bb5b8` |
