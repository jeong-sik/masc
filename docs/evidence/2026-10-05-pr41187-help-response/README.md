# Browser activity compact Help response — executed after parent integration

Original #41187 head: `2b2de24cac18a902d260277f98434860325ec14c`.
Local response checkpoint: `8c2cc2e766` (the earlier prepared response was unexecuted).
Published parent #41185: `468befeab53c0851ec4c2e8717acdbc67c361177`.
Integrated fixed source tree before evidence updates:
`0aac60cf8e0637f59ff19e135bce2e49784cb516`.

The response excludes open Help from Browser activity input ownership, including
when the compact fallback hides Help. The same PTY waits for the actual Cheat
Sheet title, tries hidden ? and Escape at 120×12, expands to 120×32, dismisses
visible Help, and checks the Off draft remains with zero preview/save requests.
Existing preview rejection, exact CAS conflict/reapply, flat-path migration,
unrelated-setting and independent Live-draft assertions remain unchanged.

The actual parent merge resolved two Dune files additively: retain Browser
activity and parent Runtime evidence dependencies, both Browser/model-form
libraries, and both test/alias/include groups. Production files auto-merged.
Browser save continues through the parent's shared workspace guard, preview,
CAS write and forced config readback helper.

## Actual local proof

Both builds use OCaml 5.5.1 and `DUNE_JOBS=2 scripts/dune-local.sh build
bin/masc_tui.exe test/test_tui_browser_activity.exe`. No full build was run.

1. For RED, remove only the new Browser `not state.help_open` guard from the
   integrated candidate. This is bug reintroduction on the integrated parent,
   not an exact-original-head binary. The actual native **15 operator-flow
   tests PASS**. The same PTY **FAILS** after hidden Escape: dismissing Help
   returns to All Lanes instead of the Browser editor. Raw ANSI output and the
   reconstructed final terminal frame are retained, with source/binary hashes.
2. Restore exactly the guard; focused build PASS. With the unchanged fixture,
   actual TUI PTY **PASS**, including both compact hidden keys and all prior
   save/conflict/migration assertions. The native activity module/test bytes
   are unchanged by this TUI dispatcher-only guard restoration.
3. Ruff PASS. Pyright reports the same one existing `object.__getitem__` error
   at fixture line 64 for both original and current fixture; zero new errors.
   Fragment parser and product/non-evidence diff whitespace checks PASS.

The new raw logs retain ANSI and trailing blank lines byte-for-byte. Earlier
isolated pure/native-fragment evidence in `2026-10-05-tui-browser-activity` remains
an original-author historical snapshot; it does not attest this integrated tree.
Current logs are local actual TUI execution against synthetic HTTP. They do not
prove a real server save, Browser execution, full suite, CI, deployment, or main
integration. No live runtime configuration was changed. Publication/review remain
root-owned; this worktree was frozen without a remote push or review post.
