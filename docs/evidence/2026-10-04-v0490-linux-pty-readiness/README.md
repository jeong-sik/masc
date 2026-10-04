# Linux PTY readiness repair

Full RC [37154278906](https://github.com/jeong-sik/masc/actions/runs/37154278906)
failed behavior verification on `4a5517c1dac84d941cb99a7b89eafe1c61b384dd`.
Compilation and all four installation platforms passed. The complete Dune log
contains two failing-target headers: Board scroll and Keeper portrait PTY.
Artifact `11286097646` has ZIP SHA256
`e725380997264bf937858b091559a5f3bb85408e50a5d9c896ee11ff76ce3b50`.

## Causes and changes

- Board's independent-window case sent Enter after the generic heading, before
  its first post arrived. It now uses the same one-post readiness check as the
  other seven cases. Comment/body scrolling and resize assertions remain intact.
- The portrait workspace-return case sent Enter at output offset `48230` while
  the completed frame still showed `[workspace mismatch]`. The first matching
  frame ends at `49012`. HTTP request counts precede client application; the
  case now waits for the recovered Keeper list and its ready `to alpha` composer.
- The first Linux repair run exposed the same gap in the later Sandbox-log
  revocation case: a manual retry preceded visible authority withdrawal. All
  four Instructions/Sandbox recovery modes now wait for `No keeper selected.`
  before that retry. Read counts, late-reply checks and navigation assertions
  remain intact.
- The otherwise-passing Home suite logged two `JSONDecodeError` handler failures
  when MCP event-stream GETs reached its POST JSON decoder. Its existing
  `RequestHttpResponse.get_response` option now answers those GETs with 405.
  POST identity, cancellation and previous-workspace receipt assertions remain.

No product code, timeout, assertion or scenario was removed or relaxed.

## Executed evidence

The official complete Board, portrait and Home entrypoints passed **30/30**
(8 + 18 + 4), exit 0, with zero HTTP handler exceptions. Execution was
2026-10-03 22:12:14–22:13:33 UTC in an isolated Linux ARM64 Docker container,
Python 3.11.2, using the actual RC4a native TUI artifact and repaired Python
fixtures. The container had no external network; fixture HTTP used loopback.
`manifest.json` binds the artifact, executable, image and source hashes.

A separate controlled Board response takes one second, within the existing
readiness deadline. The original scenario fails waiting for `Comment row 000`;
the repaired scenario passes with all original assertions. Both native runs,
the control script, response timestamps and terminal bytes are retained.

`native-fixtures.tar.gz` contains 123 files: all 122 files listed in its
`files.json` plus that manifest. Every listed size/hash was independently read
back. It includes the final 30 PTY streams/screens, raw run output, exact six
fixture/helper sources, wrapper, Board control runs, original CI failure frames
and the initial Linux run's later Sandbox failure. The initial run is explicitly
failed evidence (23 passed, then failure); it is not counted in the final 30.

This is an existing-RC-binary fixture overlay, not a new build, Linux x64
execution, production observation or successful integrated-head Full RC.
The final frozen candidate still requires independent source review and its own
complete release verification. The assembler must fold the new repair fragment
into the 0.49.0 detailed notes and consume it before freezing that candidate.
