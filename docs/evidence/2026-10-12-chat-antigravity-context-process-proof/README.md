# Antigravity context process evidence

At source head `cd9fa7e21fcb4367605addadbd43c2004ad07621`, the existing
context transport process suite ran four tests in 3.404 seconds and exited 0.
Receipt contains exact script/test hashes; test-output.txt preserves the bounded output.

Actual checks: PTY status callback projection and privacy, owned process-group
cleanup on success/timeout, private version-probe working directory, and duplicate
JSON keys rejected before status evidence publication. The CLI is a scripted
fixture, not an authenticated provider. No real account or transcript was used.

This proves the Python context transport boundary only. It does not prove prompt
body delivery, mid-turn input, OCaml stream producer changes, TUI rendering,
installed current source, or screenshots. Earlier commentary described input
transport; reading the suite established that its actual scope is context status.
The scope here is corrected accordingly. No local Dune build or CI was executed.

Input stdin/EOF process behavior remains in test_runtime_antigravity.ml and the
OCaml integration fixtures, which have not been executed in this session. Overall
multi-provider continuity, streaming and UI goal remains incomplete.
