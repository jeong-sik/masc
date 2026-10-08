# Shared footer consistency evidence

This slice extends #41685's conversation-first direction to the shared footer
used across TUI surfaces. Passive connection facts and global Keeper execution
notices no longer accompany the composer. Search position, mutation outcomes,
workspace/build warnings and armed/running actions remain.

System displays workspace paths and server version/commit/port/age on separate
bounded rows. `config_identity_rows` supplies both the renderer and source-view
height/cursor calculations.

## Checks performed

- Eight existing pure footer fitting tests passed by interpreting the actual
  message-layout/footer modules and the exact `strip_sgr` function extracted from
  the theme source. They cover explicit diagnostic callers, search, narrow key
  fitting, mismatch priority, armed actions, ANSI and leaving the screen.
  `footer-fitting.txt` records the selected tests and result. This is not a
  full application test or a built executable.
- Changed OCaml syntax checked with `ocamlc -stop-after parsing`; changed Python
  syntax checked with `ast.parse`. `source-checks.json` records exact file hashes.
- The renderer hash was refreshed after the final source edit, and its
  `ocamlc -stop-after parsing -impl bin/masc_tui_render.ml` check was rerun.
  `renderer_syntax_refresh` records the checked source commit and command.
  This refresh did not rerun the earlier footer tests or any PTY scenario.
- Independent review identified narrow System diagnostics losing paths and PTY
  fixtures using removed passive footer content. Responsive rows and current
  System-authority barriers address those findings.

## Execution still needed

The renderer integration test and updated PTY scenarios are not run. Required
follow-up covers quiet footer behavior across main surfaces, preserved warnings
and actions, System at 60/100/120 columns, and held responses across a workspace
identity change. No local Dune build, CI dispatch, executable replacement or
runtime mutation was performed.

The [full consistency ledger](../../design/tui/CONSISTENCY-PROGRESS.md) retains the
other surfaces and actual rendering verification as unfinished work.
