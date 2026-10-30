# Memory facts workspace authority verification

This repair is based on PR #41179 head
`3a6303b9098b81d570205cc4f2cf41b8d235d9f7`, whose tested base is
`6fc062feee7e33a271e09dc155d9feffee923704`. Current main advanced to
`87123f7df94a27ded447b5b05d01c2f5178de029`; its provider/namespace changes
do not change the inspected Memory TUI or fixture consumers. These results
remain pinned to the tested base and repair, rather than a newer main binary.

The fixture waits for the rendered workspace-mismatch badge, which reads the
applied authority. Two health-handler calls cannot establish that boundary:
one refresh reads identity twice before it returns its bundle to the reducer.
It then waits for B's visible health source-revision column and keeper row before
releasing A. Enter selects that fresh row; B is not recovered by manually
refreshing a retained A browser. All domain writes are refused by the fixture
assertion; the ordinary MCP initialize handshake is allowed explicitly.

Withdrawal now closes the facts selection and detail overlay, resets their
cursor, scroll, claim wrap and category, and clears the prior health table.
The scoped health request and its identity guard use the same implementation
as published #41023 (`dfdd953c51f7ca53ab389dd03be47ce170ff3c7b`). Only this
directly required health pattern and withdrawal fields are shared here; the
rest of that feature is not imported.

## Executed evidence

- Existing main product, binary SHA-256
  `5771c86ca227b59e653e56870de47091dbfc075d5673906b0852b296af470452`:
  the initial applied-identity fixture failed because A's held fact populated
  B's browser. This used the earlier single-browser fixture variant.
- Published #41179 product before navigation repair, binary SHA-256
  `14e496b3e9406d46bc3d4489056b5be8ed7d85eea037569804dcd35b6c73beb9`:
  the final visible-B-health predicate failed because the unread A facts
  browser remained selected. The later domain-write logging does not change
  that predicate or the failing branch.
- Final repaired product, binary SHA-256
  `95d6ffcfc37d11d93eb936af86cbadbd96609855a8115c9c96d7ad51eb209d20`:
  focused TUI build and two actual PTY scenarios passed. One keeps the same
  alpha name in A and B; the other opens A's fact detail, holds its refresh,
  and switches to B's beta row where alpha is absent. Both refuse A's held
  and prior claims, accept B's own facts after Enter, and observe no domain write.

Earlier attempts waiting for `MISMATCH local` on the custom facts footer or
for a hidden ordinary `snapshot r47` detail are fixture failures, not behavior
RED evidence. The final fixture uses a 160-column viewport and the visible
health source column `r47 i1`. A strict no-POST assertion also caught MCP
initialize handshakes; only that exact bootstrap method is now exempted.

Ruff passed. Pyright reports two pre-existing health-callback fixture-type
diagnostics with the same messages as the original PR file; no new diagnostics
were added. Local logs are retained as `pr41179-red-pty3.log`,
`pr41179-navigation-red-final-pty.log`, `pr41179-final-green-build.log`, and
`pr41179-final-green-pty2.log`. CI, deployment and live-provider execution were
not performed.

Reproduce from the checkout with the installed OCaml 5.5.1 toolchain:

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe
python3 test/test_tui_memory_facts_authority_pty.py _build/default/bin/masc_tui.exe
ruff check test/test_tui_memory_facts_authority_pty.py
pyright --outputjson test/test_tui_memory_facts_authority_pty.py
```

The named raw logs, baseline/current Pyright output and final Ruff output are stored in this directory. `manifest.json` pins their bytes and the tested production/test source.
