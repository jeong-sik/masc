# Terminal mouse protocol responsibility boundary

PR: [#41915](https://github.com/jeong-sik/masc/pull/41915).
Base: `0a03dd925a9a7b92a3aabc258653b8ab050d18a0`.

`Tui_decode` mixed more than 7,500 lines of domain JSON contracts with terminal
SGR/X10 mouse grammar. The grammar belongs to the byte-input boundary: it knows
no Keeper, HTTP, Board, model or filesystem state. `Tui_mouse_protocol` now owns
its closed wheel/report types and pure parsers. Consumers refer to it directly;
`Tui_decode` exposes no forwarding alias. Input buffering, held-button ambiguity,
Eio reads and surface gesture ownership remain at their existing effect edges.
The implementation was copied byte-for-byte, apart from its trailing separator;
[extraction.json](extraction.json) records the source span and digest. That is
source-scope evidence, not behavior proof. Other JSON responsibilities remain
pending; neither decoder nor main TUI is declared fully refactored.

| Changed interface | Direct consumer | Verification |
| --- | --- | --- |
| SGR/X10 report types and parsers | `masc_tui_input_decoder` | Four streaming input cases: split SGR/X10 bytes, idle truncation and overlapping button releases; [input-decoder.log](input-decoder.log) |
| Wheel, press and release grammar | terminal reports in `test_tui_decode` | Thirteen existing SGR/X10 cases; [grammar.log](grammar.log) |
| Closed wheel direction | input reader, main TUI and `masc_tui_render_prim` | Six reader scroll cases; [wheel-reader.log](wheel-reader.log), [tui-build.json](tui-build.json) |
| Byte stream to rendered Keeper selection | real worktree TUI executable | Existing PTY scenario `wheel scrolls, clicks do not`; [pty.json](pty.json), [pty.log](pty.log) |

The build and scenario were explicitly authorized by the operator's local-build
request. Commands and actual successful test counts are in [checks.json](checks.json).
The build targets only `bin/masc_tui.exe`; it is not a full repository build.
[source-sha256.json](source-sha256.json) fingerprints the changed implementation,
interfaces, direct consumers, test consumers and capture wrapper.

[capture.py](capture.py) runs the existing scenario and intercepts its completed
`send_and_wait` calls only to retain decoded terminal frames. It changes no input
or assertions. [wheel-1.txt](wheel-1.txt) shows beta after wheel down,
[wheel-2.txt](wheel-2.txt) alpha after wheel up, and [wheel-3.txt](wheel-3.txt)
beta after a title click press/release and another wheel down. Trailing spaces
are removed from the retained text. The scenario also checks composer isolation,
compact-viewport input gating, navigation and terminal-mode restoration.

The PTY uses an isolated temporary base path and fixture HTTP service. Its binary
is identified by SHA256 in the build and PTY receipts. Actual X10 streaming is
covered by the OCaml input decoder scenarios; this PTY sends SGR reports only.
There is no installed/live-service, real terminal-emulator, Linux, full CI or
release/deployment claim. No dashboard behavior changes in this unit.
