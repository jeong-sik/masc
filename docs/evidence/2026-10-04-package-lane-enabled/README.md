# Package Lane activity evidence

This change accepts `enabled` on package declarations and lets the TUI stage it
with Space before an explicit CAS save. The payload revision remains independent
of activity; desired off and observed worker state are displayed separately.

The actual inventory decoder/display passed 13 isolated cases. The actual TOML
line editor and declaration draft module passed six isolated cases, including
comments, multiline values, nested enabled keys, invalid input and retained CAS
state. Their copied source hashes and commands are in the provenance JSON files.
These runs do not link the full Masc backend or TUI.

The two affected Web component suites passed 51 cases; TypeScript and changed-file
ESLint passed. The OCaml parser accepted 21 changed ML/MLI files and Python AST
parsing accepted five changed PTY fixture files. Parser checks do not typecheck
the native backend or execute a terminal scenario.

[Chromium artifacts](../../../dashboard/evidence/2026-10-04-package-lane-enabled/)
exercise the actual component and wire decoder against synthetic HTTP responses.
The first harness intercepted a source module under `/dashboard/src/api/`; its
routing failure is retained separately. After restricting interception to actual
API paths, the scenario passed with no unexpected API calls, writes or page
errors. Desktop screenshots show off requested with incomplete reads and failed
cleanup, then configured off with retained evidence. The mobile screenshot also
records the existing horizontally scrolling table layout; it does not certify
that layout as convenient.

Native reconciliation/privacy/cleanup tests and the Space/save PTY scenario were
updated but not executed. No native backend, full TUI, Docker cleanup, CI,
deployment or integration success is claimed. See `checks.json` for source hashes,
commands and limits, and the text files for actual check output.
