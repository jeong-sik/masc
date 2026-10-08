# Machine settings reads retain one workspace authority

Baseline #41201 `690424d085919671eacc0ccfac0400d16695103c`. The real TUI fixture switches its synthetic HTTP server identity immediately after returning either the raw configuration or Machine inventory. Original code fails separately: it sends inventory after the document switched workspace, and accepts a mixed-workspace document after the inventory switched workspace. The first fixture attempt blocked without draining the PTY and did not reach the transition; that authoring failure is preserved separately in red.log and is not behavior RED.

The repair captures the existing workspace check once, checks it before the second request and before accepting both readings. Existing cancellation and stamped completion remain unchanged; an unavailable file still permits an independent inventory reading when workspace identity is intact. Fixture inventory now explicitly validates its dictionary/list shape for Python typing.

Focused TUI build passed. The complete Machine PTY fixture passed all five scenarios: original draft/conflict/ambiguous save flow, compact quit, unavailable file with independent observation, and both workspace boundaries. Changed Python Ruff/Pyright passed with zero errors. Independent read-only source review found no P0-P2. Raw logs and source/binary hashes are retained. No real machine, backend, full CI, release, or TerminalBench execution is claimed.

Commands from the isolated owner root:
```sh
opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build bin/masc_tui.exe
python3 test/test_tui_machine_activity_pty.py _build/default/bin/masc_tui.exe
ruff check test/test_tui_machine_activity_pty.py
pyright --outputjson test/test_tui_machine_activity_pty.py
```

The baseline cases were invoked individually by importing run_workspace_boundary from the fixture with the baseline binary, once for document and once for inventory. These results qualify the owner candidate only; later parent and descendant integration must preserve this boundary and retain separate evidence.
