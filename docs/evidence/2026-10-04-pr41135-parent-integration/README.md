# PR41135 parent integration and Skill withdrawal

Original PR head: `13dfb8a31f40dda913bfdb049c19d7c99afa480b`.
Local repair checkpoint: `2d8fe7ae84`.
Real merged parent: `156d2bf8bf0b53903a2fd77258233a088ee02286` (#41131).
The adjacent TOML editor conflicts retain both root activity editing and the
parent's nested activity editing/float preservation. Parent input precedence,
read-only MSX retry, mandatory CAS, and inventory fixture corrections remain.

Stopping owners and owners with complete, valid explicit-off declarations no
longer supply newly published Skills. The real publisher regression verifies
withdrawal before/after failed cleanup, replacement-only restoration, retained
frozen readers, ordinary failed observations, incomplete inventory, and manual
owners. Removing only the withdrawal filter produced the recorded RED failure;
restoring exact source and rebuilding produced five passing Skill tests.

## Executed checks

- Focused wrapper build: seven native test executables and `bin/masc_tui.exe`.
- Native: 78/79 passed. Skills5, reconciliation18, declaration10, TUI paths6,
  inventory13, reading10 passed. TUI Add-ons16/17 passed; the unchanged
  `declared_layers_use_exact_configured_owners` assertion expects `1 result row`
  while the unchanged flow renderer emits `1 record`, tracked in
  [#41174](https://github.com/jeong-sik/masc/issues/41174). The assertion remains.
- Inventory PTY: 60/80-column cases and destinations passed.
- Package PTY: seven explicit saves, Space activity staging, conflict/revision,
  retained rejected draft, late save/draft switch and action passed. Activity
  validation rows move rejected draft bytes below the initial viewport; the
  fixture now scrolls actual J keys, waits completed frames, and asserts current
  screen bytes. Earlier unscrolled assertion failures were not lost drafts.
- Two affected Web component suites: 52 passed. TypeScript and changed ESLint
  passed. Changed package fixture Ruff and Pyright passed (zero diagnostics).

The initial direct Skill executable invocation lacked copied Dune fixture files;
subsequent execution explicitly set `DUNE_SOURCEROOT` to this worktree, as the
fixture supports. Those setup failures are not counted as product regression RED.
The preserved RED is the actual publisher assertion with the filter removed.

Native build command (within opam5.5.1):

```sh
scripts/dune-local.sh build test/test_lane_addon_skills.exe test/test_lane_addon_reconcile.exe test/test_lane_addon_declaration.exe test/test_tui_lane_declaration_path.exe test/test_tui_lane_inventory.exe test/test_tui_lane_addons.exe test/test_tui_lane_addon_reading.exe bin/masc_tui.exe
DUNE_SOURCEROOT="$PWD" _build/default/test/test_lane_addon_skills.exe
python3 test/test_tui_lane_inventory_pty.py _build/default/bin/masc_tui.exe
python3 test/test_tui_lane_package_pty.py _build/default/bin/masc_tui.exe
```

Other built test executables ran individually. From dashboard:

```sh
pnpm test src/components/lane-addons-panel.test.ts src/components/lane-declaration-editor.test.ts
pnpm exec tsc --noEmit --pretty false
pnpm exec eslint src/api/lane-addons.ts src/components/lane-addons-panel.ts src/components/lane-addons-panel.test.ts src/components/lane-declaration-editor.test.ts
```

TUI SHA256 at PTY execution and after restored build:
`f4c419ddea897edf09ac9263062297754d54ae9e18a2d3e0afe88c6c4c4c8e39`.
These are local focused native and synthetic HTTP PTY/Web checks; no real Docker
cleanup, production runtime, full suite, Full RC, deployment or release proof.
Historical evidence under `2026-10-04-package-lane-enabled` remains unchanged.
