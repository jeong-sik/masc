# Librarian Lane editor visual check

`local-component-preview.png` is a 1440×900 Chromium screenshot of the actual
`RuntimeExactLaneEditor` component served by Vite on 2026-09-24. The fixture
uses synthetic runtime IDs and endpoints. It shows the HTTP/CLI groups and the
`missing_deadline` diagnostic. The temporary preview entry was removed after
capture; this is local rendering evidence, not a deployed Dashboard receipt.

Validation alongside the screenshot: `pnpm typecheck`, targeted Vitest for
`runtime-toml-config` and `runtime-toml-editor` (100 tests), and ESLint passed.
TUI and OCaml behavior is pending repository CI because this checkout does
not build the TUI locally.
