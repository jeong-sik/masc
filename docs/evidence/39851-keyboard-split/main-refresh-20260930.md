# Keyboard split refreshed onto the current Home implementation

The conflict repair combines PR #40234 at
`43f3519aee26e275303f3a2915b31ffe73a532a6` with main
`04256f2b1d46fe9d49f884215b2d6c0025defa3a`.

The 24 helper modules retain their existing owners. Their functions, classes
and fixture declarations now come from that main source, including Home,
Board comment pagination, terminal input handling and standalone Lane fixtures.
The removed attention-age scenario and its Dune stanza remain removed.

Four conflicting consumers and five new Home consumers use the actual helper
owners. Their function/class ASTs match main after normalizing only module
qualifiers. Dune rules declare the transitive imports of their Python consumers;
their actions, aliases and the current Home rules remain unchanged.

The accompanying `main-refresh-20260930.json` records these checks:

- 373 function/class bodies are byte-identical to main; no missing or extra
  definitions. All 131 top-level fixture/registry values also match.
- `--list` matches: 44 families and 152 description occurrences. Listing opens
  no TUI or PTY.
- All 152 relevant Dune dependency declarations include their actual Python
  import closure. The removed attention-age files are absent.
- 138 changed Python files parse and 135 test modules import successfully.
- 33 existing Python unit cases pass across scenario selection, fixture
  shutdown, Keeper row selection, stall observations and artifact comparison.
  The two HTTP fixture tests first met the sandbox's loopback restriction;
  both passed when rerun with loopback access.
- Ruff's undefined-name check and `git diff --cached --check upstream/main` pass. The comparison excludes unchanged main terminal-frame artifacts, whose trailing screen cells are intentional.

These are source/import and Python helper results. No Dune build, TUI/PTY
execution or CI run was performed. Runtime equivalence remains unverified;
the full terminal checks belong to the explicit Release/Tag validation cycle.
The older artifacts in this directory retain their original baseline and do
not establish this refreshed source.
