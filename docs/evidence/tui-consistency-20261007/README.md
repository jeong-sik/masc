# Shared footer consistency evidence

This slice extends #41685's conversation-first direction to the shared footer
used across TUI surfaces. Passive connection facts and global Keeper execution
notices no longer accompany the composer. Search position, mutation outcomes,
workspace/build warnings and armed/running actions remain.

System displays workspace paths and server version/commit/port/age on separate
bounded rows. `config_identity_rows` supplies both the renderer and source-view
height/cursor calculations.

## Current syntax evidence

`source-checks.json` records fresh parser results and SHA-256 identities for
its listed source files. These checks establish syntax only. The archived
`footer-fitting.txt` and earlier prose reports are historical evidence, not
execution or independent-review receipts for this revised tree. No footer
suite was rerun for this repair. The PTY scripts the manifest used to list were
removed by main (#42155), so the manifest now covers OCaml sources only.

## Execution still needed

The renderer integration test and updated PTY scenarios are not run. Required
follow-up covers quiet footer behavior across main surfaces, preserved warnings
and actions, System at 60/100/120 columns, and held responses across a workspace
identity change. No local Dune build, CI dispatch, executable replacement or
runtime mutation was performed.

The [full consistency ledger](../../design/tui/CONSISTENCY-PROGRESS.md) retains the
other surfaces and actual rendering verification as unfinished work.
