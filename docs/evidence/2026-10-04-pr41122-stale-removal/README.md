# Known stale declaration removal

Baseline PR head `4ea9a34a60f7e0b81839a477e94ad4573446c4ec` with real parent
merge `4650e496523f97f306382b37e9f549506891ac1d` (#41121).
Addresses duplicate P2 comments 4177700304 and4178026214.

Web compares current declaration id/path/revision with the installed owner.
TUI joins declaration id/path/exact worker id and compares desired/applied
configuration revisions; applied_revision is projected from the runtime owner's
configuration revision, not the package revision. A known mismatch explains
Edit TOML and refresh recovery before offering removal. The TUI d handler also
refuses dispatch. Unknown inventory, missing revisions and manual owners are not
inferred to be stale. Backend removal/CAS checks are unchanged.

The existing Web pending-revision fixture failed with the new disabled-control
assertion on baseline, then both affected suites passed 42 tests after the repair.
Whole dashboard TypeScript and changed-file ESLint passed. Focused native build
of test_tui_lane_addons.exe and masc_tui.exe passed. Native 16/17 passed including
stale/matching/unknown/manual checks; unchanged #41174 expects 1 result row while
the flow renderer emits 1 record. That assertion remains and is not counted PASS.

An actual matching-binary PTY checks zero detach POSTs for stale d, refreshes the
same declaration to matching revision, and observes exactly one detach POST for
that worker. The initial attempt passed behavior checks but omitted the final
Dashboard quit; pty2.log is the completed scenario. Python Ruff/Pyright passed.
TUI SHA256: 24bfb3d04258e25b3edadaf1c8d861e00b0985fab6cfd24c46d4995a0b8b83a2.

```sh
opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_tui_lane_addons.exe bin/masc_tui.exe
_build/default/test/test_tui_lane_addons.exe
PYTHONPATH=test python3 -c 'import test_tui_lane_operator_pty as t; t.stale_removal("_build/default/bin/masc_tui.exe")'
# dashboard
pnpm test src/components/lane-addons-panel.test.ts src/components/lane-declaration-editor.test.ts
pnpm exec tsc --noEmit --pretty false
pnpm exec eslint src/components/lane-addons-panel.ts src/components/lane-addons-panel.test.ts
```

Synthetic HTTP only; no actual declaration deletion or worker cleanup was
performed. No browser rerun, full suite, CI, Full RC or deployment claim.
Raw logs are preserved, including trailing blank-line warnings.
