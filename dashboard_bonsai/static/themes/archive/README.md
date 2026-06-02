# Archived themes

These theme stylesheets are preserved as brand-voice references; they are
**not** linked from `bonsai_index_html` (`lib/server/server_routes_http_pages.ml`)
and they are **not** consumed by any build step.

Origin: `dashboard_bonsai/static/colors_and_type.css` (hand-written, 566L,
deleted in Wave 2 Bonsai swap to the codegen SSOT
`dashboard_bonsai/static/colors_and_type.generated.css`). The active themes
live in `dashboard/design-system/tokens/source.ts` and are emitted to the
`.generated.css` file by `pnpm tokens:build`.

| File | Source theme | Notes |
|------|--------------|-------|
| `cyberpunk.css` | `[data-theme="cyberpunk"]` | Neon / Share Tech Mono palette |
| `terminal.css` | `[data-theme="terminal"]` | Phosphor green CRT palette |
| `parchment.css` | `[data-theme="parchment"]` | Warm in-app dark theme |

If a future iteration revives one of these themes, port the block back into
`dashboard/design-system/tokens/source.ts` so the codegen pipeline emits it
into `colors_and_type.generated.css`. Do not re-introduce a hand-written
override on top of the generated file.
