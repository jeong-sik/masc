# TUI Browser activity draft and save

All Lanes → select a Browser backend → Space opens a workspace/backend-owned
activity draft. Space changes intent without writing. Explicit s uses the
existing preview + raw Runtime CAS save path. Successful saves reread the file
and Lane inventory; conflicting revisions require explicit field-only reapply.
Workspace/view round trips retain drafts and reject old callbacks. A clean
same-path draft follows a newly read file; dirty/unconfirmed drafts keep their
original base. A changed config path requires explicit discard.

Automation activity also moves accepted flat `[browser]` paths into
`[browser.automation]`. The resulting configuration is re-parsed and checked for
equality with the original Browser configuration except for the chosen flag.
Unrelated settings are retained. Inline/dotted forms the existing line editor
cannot preserve are refused before any save with source-editor guidance.

## Executed

`ACTIVITY_OCAML_BIN=<OCaml 5.5.1 bin> python3
 docs/evidence/2026-10-05-tui-browser-activity/check-draft.py --label after`

- Actual pure draft/config/parser/line-editor/receipt sources compile and link;
  **15 operator-flow tests pass**. The generated Browser_lane module is only
  `module Lane_name = Browser_lane_name`, naming the actual enum source. There
  is no substitute Browser behavior. Source hashes and exact commands are in
  `after-provenance.json`, execution output in `after.txt`.
- Parsing of the changed ML/MLI files is recorded in `syntax.json`.
- New PTY scenario and runner Python AST pass. Diff whitespace passes.
- Text logs have trailing whitespace/EOF blank lines normalized only.

## Authored, not executed

`test/test_tui_browser_activity_pty.py` drives a separately built matching TUI
against synthetic HTTP: open/toggle/back/reopen never write; preview refusal
keeps intent; a CAS conflict cannot overwrite another writer; explicit reapply
retains unrelated config and migrates flat paths; changing live activity remains
a separate unsaved draft. The focused alias and runtest dependency are declared.
This scenario has not been run. Neither full native TUI main/render type/link,
PTY/terminal rendering, real server save nor Browser execution is established.
No local Dune, CI, merge, runtime mutation or deployment was performed.

## Review limitation / remaining work

The common line editor replaces changed assignment rows and does not preserve
inline comments attached to an enabled or moved path assignment. Unrelated
lines/comments and configuration values are retained. This is a non-blocking P3
review observation; no claim of preserving every source byte is made.

Exact-head independent review, main/native integration and Browser Web controls
remain. Executable/profile changes still require a server restart. The overall
Lane UX goal is incomplete.
