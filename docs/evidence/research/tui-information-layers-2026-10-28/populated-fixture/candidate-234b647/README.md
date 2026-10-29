# Queue and Help observation for source 234b647

This is a manual observation, not a PTY regression test or production run.
On 2026-10-28 around 22:11–22:15 KST, a private workspace, empty home and
[read-only loopback fixture](../fixture.py) supplied synthetic chat and queue
rows. Every POST returned HTTP 405; no real Keeper, credentials or production
server was used. The private tmux server and fixture were stopped afterwards.

[Minimal manual checks #40692580048](https://github.com/jeong-sik/masc/actions/runs/40692580048)
completed successfully on macOS arm64 for source
`234b647137d3ce4cf352717fc58e2bc03855fcf2`, with workflow SHA
`197f56852c59eb5e7c3c2305974b58c73c9c23f9`. Its receipt and the downloaded
binary agreed on SHA-256
`0767ca955e5c9b39b0b057a64a53658e75a07829fad100379426252fb238400b`;
`--build-commit` also returned that source. The three passing selected suites
were `test_tui_detail_reading`, `test_tui_board_successor`, and
`test_tui_usage_scope`; none exercises Queue. This is not full regression,
installation, deployment or real-server proof.

At 80×24 in tmux 3.6a with `TERM=xterm-256color`, a synthetic bracketed paste
in Queue showed `Paste lost; retry` in the panel's bottom border while the
footer retained the fixture build mismatch. Sending Esc immediately followed
by another synthetic bracketed paste in one tmux input produced the same notice
in the chat input padding, with an empty draft. This is one observed sequence,
not a proof of every transition or terminal timing.

With empty chat input, `?` opened Help. Pasting `HELP-234B-MARKER` while Help
was visible changed the underlying composer summary and left that text in the
chat draft after Esc. No message was sent. This is a negative observation of
source `234b647`; it does not prove behavior of the subsequent Help fix.

Captures contain synthetic data only. Trailing spaces were removed after
`tmux capture-pane -p`; content, line order and visible text were retained.

| Capture | SHA-256 |
| --- | --- |
| [Queue rejected-paste border](queue-paste-status.txt) | `c6b11c58f80a6a75842f7f4617399be1c2c874343734fb386323aceb53826965` |
| [Chat after queued close and paste](chat-transition-paste-status.txt) | `3b0f2143ebd68022631aead9f28b24688691644d6e21a76aa2fb74beb217612d` |
| [Help paste changed underlying draft](help-chat-paste-bug.txt) | `53265e64bdb14a4421fc70136d8d01e2e3d8fd97da550006abc5ac5ab95da577` |
| [Chat draft after Help closed](chat-after-help-bug.txt) | `e057d9115f2734ba0ac5c864efa978163bea13e144f78caa1354afa64b0127c9` |
