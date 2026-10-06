# Exact activity help ownership after parent integration

Original #41166 head `2c6f724d53dc0daf713125b7fdf87ae7c7894345` was
checkpointed with the compact-help regression and merged with published parent
#41162 `758d8d672e90056c61ad07db996c2cf70b692797`.
Dune conflicts retain both Exact activity and parent runtime-evidence libraries
and tests. Async dispatch retains Exact callbacks plus the parent's generation-
stamped Runtime reads. The shared save-helper extraction preserves the parent's
forced reread after commit.

The actual compact viewport maps to Too_small before the help frame. The activity
key helper therefore intercepted Escape and closed the underlying draft while
help was open. The fix adds `not state.help_open` to that helper. Global compact
key ownership is unchanged: hidden help ignores ?/Escape, then can be dismissed
normally after expansion.

The same final fixture was executed against both binaries. `red.log` records
both hidden keys and fails after compact Escape on the unfixed binary. `green.log`
passes both keys and retains the full existing preview rejection, exact CAS
conflict/reapply, candidate preservation and Required-lane refusal assertions.
The ten native draft/save cases also pass. HTTP is synthetic; this is actual
native PTY behavior, not backend writes, model execution, full CI or release proof.

Commands from the worktree root:

```sh
opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/masc_tui.exe test/test_tui_exact_activity.exe
_build/default/test/test_tui_exact_activity.exe
python3 test/test_tui_exact_activity_pty.py /tmp/pr41166-before-help-fix.exe
python3 test/test_tui_exact_activity_pty.py _build/default/bin/masc_tui.exe
ruff check test/test_tui_exact_activity_pty.py
pyright --outputjson test/test_tui_exact_activity_pty.py
```

Ruff passes. Pyright reports two inherited inventory-object indexing errors;
the original-head fixture checked in the same dependency context has identical
rule/message diagnostics. This is not type-clean. No native test ran during
the temporary baseline typecheck swap, and the final fixture was restored.
Earlier attempts used an obsolete help phrase, then incorrectly expected hidden
help dismissal; these were fixture assumptions, not the final RED evidence.
Help readiness now uses the actual Cheat Sheet title. Historical isolated/native
parser evidence remains unchanged; raw current logs are copied exactly.
