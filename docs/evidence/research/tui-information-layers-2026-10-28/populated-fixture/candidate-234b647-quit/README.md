# Quit confirmation expiry observation for source 234b647

This manual observation used the macOS arm64 TUI from
[Minimal manual checks #40692580048](https://github.com/jeong-sik/masc/actions/runs/40692580048),
source `234b647137d3ce4cf352717fc58e2bc03855fcf2`. Its downloaded executable
SHA-256 was `0767ca955e5c9b39b0b057a64a53658e75a07829fad100379426252fb238400b`;
its receipt and `--build-commit` agreed on that source. This is an earlier
candidate and does not establish the behavior of a later repair.

On 2026-10-28 between 22:45 and 22:51 KST, the TUI ran with an empty home, a
private synthetic workspace and the [read-only loopback fixture](../fixture.py).
The fixture denies every POST and does not run a Keeper or use credentials.
In tmux with `TERM=xterm-256color`, `SYNTHETIC-DRAFT` was typed in chat at
80×24 without sending it. The window was resized to 80×4, then `q` displayed
the compact confirmation. After 14 seconds, the confirmation was no longer
visible. A second `q` closed the tmux session; `tmux has-session` returned
exit 1 with “no server running”. Starting the same binary and workspace again
at 80×24 showed an empty chat input. The sequence was observed twice; the
captures below are from the second run. The private tmux server and fixture
were stopped afterwards.

This demonstrates loss of a synthetic, unsent draft in that earlier binary
under the observed sequence. It is not evidence about a real user's workspace,
a production server, other terminals or the later candidate. The frames were
captured with `tmux capture-pane -p`; trailing spaces and empty lines were removed.

| File | SHA-256 |
| --- | --- |
| [before-resize.txt](before-resize.txt) | `995d6a2e3f70c70c0a7f30c01c01c406da13e58e0cf9c2b91568f5fc9e246462` |
| [first-q.txt](first-q.txt) | `cb6860b26675fb773e3b43f098380d98c4c37805859f07b1c7f2e293c4348cf3` |
| [after-expiry.txt](after-expiry.txt) | `40e61a67f94673aae6e15375db22bd9dd04abb2ac2831a334fd17315649609d2` |
| [after-restart.txt](after-restart.txt) | `c822a452a61e2819c638446d39a366c21400f8651295e3ac5c342b696d7210ca` |
