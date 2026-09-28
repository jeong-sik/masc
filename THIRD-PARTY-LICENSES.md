# Third-party notices

MASC source code is MIT-licensed. The bundled fonts retain their SIL Open Font
License 1.1 and copyright notices. Complete upstream notice wording ships
beside the font files in the dashboard public assets; Vite copies that directory
into the dashboard release bundle. The viewer ships its own Cinzel notice.

| Font family | Bundled notice | Upstream |
|---|---|---|
| EB Garamond | [OFL](dashboard/public/assets/fonts/EBGaramond-OFL.txt) | [EB Garamond](https://github.com/octaviopardo/EBGaramond12) |
| JetBrains Mono | [OFL](dashboard/public/assets/fonts/JetBrainsMono-OFL.txt) | [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) |
| Noto Sans KR | [OFL](dashboard/public/assets/fonts/NotoSansKR-OFL.txt) | [Google Fonts distribution](https://github.com/google/fonts/tree/main/ofl/notosanskr) |
| Cinzel | [dashboard OFL](dashboard/public/assets/fonts/Cinzel-OFL.txt), [viewer OFL](viewer/assets/fonts/Cinzel-OFL.txt) | [Cinzel](https://github.com/NDISCOVER/Cinzel) |

The notices come from Google Fonts `ofl/<family>/OFL.txt`, checked against
copyright metadata in the bundled fonts on 2026-09-08, with trailing whitespace
normalized. Font subset filenames
and CSS weights do not change their license.

## Bundled Skill files

Built-in Skills ship inside the binary and are installed into a workspace's Skill
source. A file adapted from another project carries its notice in the same package.

| File | Notice | Upstream |
|---|---|---|
| `skills/root-cause-first/references/root-cause-tracing.md` | [MIT](skills/root-cause-first/references/superpowers-LICENSE.txt), Copyright (c) 2025 Jesse Vincent | [obra/superpowers](https://github.com/obra/superpowers) `skills/systematic-debugging/root-cause-tracing.md` |

## Adapted TUI source

The TUI's imp emblem adapts openai/codex's empty-state animation. The adapted
files say in their header what was kept and what was changed; Codex's license
and NOTICE sit beside them.

| File | Notice | Upstream |
|---|---|---|
| `bin/masc_tui_imp_emblem.ml` | [Apache-2.0](bin/codex-empty-state-animation-LICENSE.txt), [NOTICE](bin/codex-empty-state-animation-NOTICE.txt), Copyright 2025 OpenAI | [openai/codex](https://github.com/openai/codex) `codex-rs/tui/src/empty_state_animation/{renderer,lighting,sequence}.rs` at `5c5308fc9a9e` |
| `bin/masc_tui_imp_shape.ml` | [Apache-2.0](bin/codex-empty-state-animation-LICENSE.txt), [NOTICE](bin/codex-empty-state-animation-NOTICE.txt), Copyright 2025 OpenAI | [openai/codex](https://github.com/openai/codex) `codex-rs/tui/src/empty_state_animation/geometry.rs` at `5c5308fc9a9e` |
