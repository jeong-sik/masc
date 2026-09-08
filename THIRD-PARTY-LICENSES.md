# Third-party font notices

MASC source code is MIT-licensed. The bundled fonts retain their SIL Open Font
License 1.1 and copyright notices. Complete, unmodified upstream notices ship
beside the font files in the dashboard public assets; Vite copies that directory
into the dashboard release bundle. The viewer ships its own Cinzel notice.

| Font family | Bundled notice | Upstream |
|---|---|---|
| EB Garamond | [OFL](dashboard/public/assets/fonts/EBGaramond-OFL.txt) | [EB Garamond](https://github.com/octaviopardo/EBGaramond12) |
| JetBrains Mono | [OFL](dashboard/public/assets/fonts/JetBrainsMono-OFL.txt) | [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) |
| Noto Sans KR | [OFL](dashboard/public/assets/fonts/NotoSansKR-OFL.txt) | [Google Fonts distribution](https://github.com/google/fonts/tree/main/ofl/notosanskr) |
| Cinzel | [dashboard OFL](dashboard/public/assets/fonts/Cinzel-OFL.txt), [viewer OFL](viewer/assets/fonts/Cinzel-OFL.txt) | [Cinzel](https://github.com/NDISCOVER/Cinzel) |

The notice bytes come from Google Fonts `ofl/<family>/OFL.txt`, checked against
copyright metadata in the bundled fonts on 2026-09-08. Font subset filenames
and CSS weights do not change their license.
