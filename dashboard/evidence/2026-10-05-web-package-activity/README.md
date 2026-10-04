# Web package activity without removal

Parent: `fa6a2426e3793354ba647045842c7066d06038c0` (#41206).

The declaration table opens a dedicated On / off panel. Its workspace/file/ID
owner retains only activity intent and uses the existing declaration read/CAS
save API. Raw TOML drafts remain independent. AST value ranges preserve other
bytes; only the root enabled value changes. Omitted enabled means On, matching
the backend contract. A changed ID or invalid declaration cannot be toggled.

## Executed evidence

- `tests.txt`: 110 tests / 6 files, including existing installer, declaration
  editor and workspace consumers. Cases cover comments/quoted keys/prototype
  keys, implicit On, explicit Off/On, CAS conflict/reapply, retained raw drafts,
  navigation, workspace isolation, uncertain transport/durability and combined
  file/inventory refresh. TypeScript and scoped ESLint exit 0.
- `browser-result.json`: actual styled components, owner and API in Chromium
  with synthetic HTTP. Eight scenarios; 14 recorded Lane API reads and four
  explicit save requests (one rejected conflict, two acknowledged saves, one
  simulated commit with a lost response). No detach/remove or automatic repeat
  request; no page errors or unexpected API routes. Desktop/mobile screenshots.
- `checks.json`: commands and actual exit codes. Text logs trim only trailing
  EOF whitespace; gzip copies and raw SHA256 retain exact output.
- `manifest.json`: source/artifact hashes.

One early test attempted a synchronous region lookup immediately after an
asynchronous workspace return. Waiting for the actual remount fixed the test
setup; it is not claimed as a product regression or a before/after bug proof.

## Limits

The fixture mounts the actual Add-ons panel, not the complete SPA. HTTP data is
synthetic: no real declaration file, backend parser, worker cleanup, image,
native TUI/PTY, CI, main integration or deployment ran. Off save is not cleanup
completion; displayed file/observed configuration/save receipt are distinct.
Manual refresh is one read, not continuous submitted-revision tracking (F8).
Target-preserving links (F7), Goal D3/D4 and native/main integration remain under
the full goal. Inherited loader races are not fixed by this Web change.
