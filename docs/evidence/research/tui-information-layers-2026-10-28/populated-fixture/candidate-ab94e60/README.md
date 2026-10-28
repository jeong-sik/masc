# Queue observation for source ab94e60

This is a manual observation, not a PTY regression test or a production run.
On 2026-10-28 around 21:53–21:56 KST, a private workspace, empty home and
[read-only loopback fixture](../fixture.py) supplied synthetic chat and Queue
rows. All POSTs returned HTTP 405; no real Keeper, credentials or production
server was used. The private tmux server and fixture were stopped afterwards.

[Minimal manual checks #40677500173](https://github.com/jeong-sik/masc/actions/runs/40677500173)
completed successfully on macOS arm64 for source
`ab94e60dff26500d2674e91a85d80ee88e0bc2df`, with workflow SHA
`197f56852c59eb5e7c3c2305974b58c73c9c23f9`. Its receipt and the downloaded
binary agreed on SHA-256
`9b3242252862c45991dc4ee36de879705655cb9788fb3dd343755230f027ebdb`;
`--build-commit` also returned the source SHA. The three selected suites were
`test_tui_detail_reading`, `test_tui_board_successor`, and
`test_tui_usage_scope`; none exercises Queue. This is not full regression,
installation, deployment or real-server proof.

At 80×24 in tmux 3.6a with `TERM=xterm-256color`, Ctrl-T opened Queue; two
Down presses selected the first waiting event. `?` opened Help, a literal UTF-8
`ㅓ` sent via tmux moved Help from lines 1–16 to 2–17, and Esc restored the
selection. This does not establish physical keyboard or IME composition
behavior. Enter displayed the selected event's detail. After returning, `n`
showed the fixture's HTTP 405 refusal; no successful priority change was
performed. A synthetic bracketed paste in Queue produced `Paste lost; retry`.
After closing Queue, a synthetic chat draft survived opening and closing it.
The fixture server has a different build identity, as the footer reports.

The captures retain synthetic data only. Trailing spaces were removed after
`tmux capture-pane -p`; content, line order and visible text were retained.
This observation covers source `ab94e60`, before any later unbuilt follow-up.

| Capture | SHA-256 |
| --- | --- |
| [Queue selected event](queue-selected.txt) | `f4c2f9fbbed73b703ea1666fee422c86cd91055bf91904a683dfad8e212ea99b` |
| [Help opened from Queue](help-before.txt) | `df983a485c5868151f90e27365b73763fa3010106ed1d6a452034409905eb2d0` |
| [Help after UTF-8 Hangul j key](help-hangul.txt) | `f11b421b15ac6f005775de2345dc2eba9f64108be7347103e989b7e84fbcab9d` |
| [Queue after Help closed](queue-after-help.txt) | `f4c2f9fbbed73b703ea1666fee422c86cd91055bf91904a683dfad8e212ea99b` |
| [Selected event detail](queue-detail.txt) | `80bbcbc8cb1905fddac903b7fcc6a8a4ba2a2ad53020cef83a9bc2ee1c25755f` |
| [Read-only priority refusal](queue-priority-refused.txt) | `519ca1e14c7923c8b8566f9744d61344694a910fa05bdb28c7b61cbb6928a618` |
| [Rejected paste notice](queue-paste-refused.txt) | `d401d67213a36afe9d8e0e38647f2342846ec65384df1e222528e4604efc1613` |
| [Chat draft after Queue closed](chat-draft-return.txt) | `d0ec618aba522c90914b9596873739d3667e8e1fa7e403a78d857d7b91aaa104` |

## Help paste ownership counterexample

In a second isolated fixture run around 22:04–22:06 KST, `?` opened Help
over a chat with an empty draft. A synthetic bracketed paste,
`HELP-PASTE-MARKER`, appeared in the composer summary while Help remained
open and in the chat draft after Esc. No message was sent. After clearing that
synthetic draft, the same operation with Help above Queue produced
`Paste lost; retry` and left the composer empty. This is a negative observation
for source `ab94e60`; it does not prove the behavior of a later fix.

| Capture | SHA-256 |
| --- | --- |
| [Help over empty chat before paste](help-chat-before-paste.txt) | `df983a485c5868151f90e27365b73763fa3010106ed1d6a452034409905eb2d0` |
| [Help after paste changed underlying draft](help-chat-after-paste.txt) | `812baadde815c38eb5ad76f2ad548c16559f4ba418708b182ccd9a2826c1ae17` |
| [Chat draft after Help closed](chat-after-help-paste.txt) | `6f46ab1dded86c42aeb6dc33c593810fd70468751ac88678ec32dbf529cce6d2` |
| [Help over Queue rejected paste](help-queue-after-paste.txt) | `1abdad27561e778c9f17b6888dd77a529f34f875d33723def5f2f5e10fc24d62` |
