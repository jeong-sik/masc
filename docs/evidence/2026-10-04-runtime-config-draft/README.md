# Runtime config editor recovery and revision guard

Issue #41100, B1/B3. Parent source: `dd5e691f2ce78a3dbd10c22965107344c3b39248` (#41102).

The raw save now compares the editor's captured source revision under the
existing config write lock. A conflict returns the current document without
changing the file, runtime cache or exact registry. Web and TUI submit the same
required revision. The TUI account form reads fresh text and its revision at
submit before previewing and saving.

The TUI retains failed raw edits in process memory, keyed by canonical workspace
identity and exact config path. It displays that draft, reopens it in the editor,
reads a current snapshot without silently adopting it, and offers separate
compare/adopt-revision/replace-text/discard actions. Only a matching durable
receipt clears a submitted draft. Drafts do not survive quitting the TUI.

## Checks performed

- OCaml 5.5.1 parser-only checks for 17 changed OCaml files: `parser.log`.
- Direct isolated OCaml 5.5.1 compilation and execution of the actual pure edit
  session module and its test: **3/3 operator flows passed**, `isolated-edit.log`.
  It checks refusal followed by concurrent edits and explicit retry, deliberate
  replacement, and rejection of another config path. It does not compile the TUI.
- Python AST parsing for the three affected PTY sources; no PTY execution.
- Web evidence is in [the dashboard evidence directory](../../../dashboard/evidence/2026-10-04-runtime-config-cas/README.md):
  focused Vitest 320/320, TypeScript check, actual Chromium using synthetic HTTP.
  The integration copied those exact source bytes; `web-source-readback.json`
  compares their hashes. These results do not prove the backend or TUI integration.

`checks.json` records the parser files and tested source hashes. Backend tests
were authored for actual HTTP 200 → stale 409 → fresh retry, malformed revisions,
and unchanged file/registry after conflict. The new PTY scenario opens the real
editor twice, verifies draft retention across preview failure and current-file
read, observes a guarded conflict, then adopts and retries. Existing account-form
and workspace-replacement fixtures were updated to the server's source identity.

## Review corrections and limits

Independent source review caught an initial TUI plain SHA-256 calculation that
did not match the server's domain-separated source revision. The TUI now calls
`Runtime.config_observation` directly; Python fixtures use that same documented
prefix. An initial dependency concern was withdrawn after checking that digestif
already existed in the parent executable's direct dependencies.

Native backend/TUI compilation, the backend test executables, actual TUI PTY,
CI, deployment and merged integration are **not verified** by these checks.
Independent source review and GitHub approval are separate from these results.
