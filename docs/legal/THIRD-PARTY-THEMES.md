# 번들된 색 스킴의 출처

masc TUI 는 색 스킴 47개를 함께 배포하며 `config/themes/` 디렉터리의 TOML 테마를
지원한다. 그중 `default-dark`, `default-light`, `dungeon-gold`, `norton`, `msx`,
`pc-tools`, `msc`, `cyber`, 그리고 아래 절의 레트로 프리셋 4개(`norton-commander`,
`msx-retro`, `pc-tools-vintage`, `cga-classic`)는 masc 자체 것이고,
**나머지 35개는 다른 사람이 만든 것**이다. 이 문서가 누가 만들었고 어떤 조건으로 쓰는지를 적는다.

### masc 자체 레트로 프리셋 4개 (2026-09-05)

`norton-commander`, `msx-retro`, `pc-tools-vintage`, `cga-classic` 은 tinted-theming
값이 아니라 클래식 UI(노턴 커맨더, MSX, PC Tools/Turbo Vision, CGA)의 디자인을
masc 가 직접 base16 으로 옮긴 것이라 다른 사람의 라이선스 조항이 붙지 않는다.
번들 전에 `test_tui_theme_contrast` 의 가독성 계약을 독립 계측(python3 이식판,
상수는 masc_tui_color.ml 에서 그대로)으로 통과시켰고, 계측 원문은
`artifacts/evidence/task-1343-contrast-receipts.json` 에 남는다.

`LICENSE-AUDIT-2026-04.md` 가 "의존성 license 인벤토리 | 미점검" 으로 남겨둔 항목 중
색 스킴 부분에 해당한다.

## 값을 어디서 가져왔나

전부 [tinted-theming/schemes](https://github.com/tinted-theming/schemes) 의
`base16/*.yaml` 에서 받았다. 각 스킴을 만든 사람이 자기 값을 올려두는 곳이고,
파일마다 `author` 줄이 함께 들어 있어 값과 출처가 따로 놀지 않는다.

손으로 옮겨 적지 않는다. 16개 슬롯은 순서가 있어서 한 칸만 밀려도 "한 색만 미묘하게
틀린 테마" 가 되고, 이게 제일 눈에 안 띄는 종류의 오류다. 실제로 2026-08-28 점검에서
기존 15개 중 3개가 원본과 달랐다 — `everforest-dark` 는 base02 부터 한 칸씩 밀려
있었고, `rose-pine` 은 base0F 한 자리, `catppuccin-macchiato` 는 base06/07 두 자리가
달랐다. 셋 다 원본 값으로 되돌렸다.

## 지켜야 할 것

tinted-theming/schemes 는 MIT 이고, MIT 은 **저작권 표시와 허가 문구를 함께
배포할 것**을 요구한다. 그래서 아래 원문을 그대로 싣는다.

```
Copyright (c) 2022 Tinted Theming (https://github.com/tinted-theming)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

이름은 원래 이름 그대로 쓴다. `dracula` 를 `dracula` 라고 부르는 것은 그 스킴을
가리키는 것이지 그 프로젝트가 masc 를 만들었다고 말하는 것이 아니다. 다만 어느
프로젝트든 이름 사용을 제한한다고 밝히면 그때 이름을 바꾸고 이 줄을 고친다.

### `monokai` 한 줄 (2026-08-28 확인)

이름만 보면 걸리는 것이 하나 있어 적어둔다. Monokai 에는 유료 제품인 **Monokai
Pro** 가 따로 있는데, masc 가 싣는 것은 2006년 원본이고 Pro 의 필터 값이 아니다.
Pro 의 라이선스 문구도 `Monokai Pro extensions` 로 범위가 그쪽에 한정된다.

원본 값은 tinted-theming 말고도 Microsoft 가 VS Code 내장 테마로 MIT 배포한다
(`microsoft/vscode` 의 `extensions/theme-monokai`, 출처는 MIT 인 Colorsublime-Themes).
"라이선스가 없으니 제한도 없다" 가 아니라 실제 허가가 있는 경로다.

상표는 확인된 범위에서 걸리는 것이 없다. 다만 미국 등록부만 봤고 **EU·Benelux·WIPO
는 확인하지 못했다** — 원저자가 네덜란드 사람이라 이 공백은 그냥 공백이다.

## 목록

`원본` 열은 tinted-theming 에서의 파일 이름이다. masc 쪽 이름과 다른 경우 `←` 로
표시했다.

| masc 이름 | 원본 | 만든 사람 | 조건 |
|---|---|---|---|
| `default-dark` | — | masc | 이 저장소의 MIT |
| `default-light` | — | masc | 이 저장소의 MIT |
| `solarized-dark` | `solarized-dark` | Ethan Schoonover (modified by aramisgithub) | MIT (tinted-theming) |
| `solarized-light` | `solarized-light` | Ethan Schoonover (modified by aramisgithub) | MIT (tinted-theming) |
| `gruvbox-dark-hard` | `gruvbox-dark-hard` | Dawid Kurek (dawikur@gmail.com), morhetz (https://github.com/morhetz/gruvbox) | MIT (tinted-theming) |
| `nord` | `nord` | arcticicestudio | MIT (tinted-theming) |
| `dracula` | `dracula` | clach04 (https://github.com/clach04) | MIT (tinted-theming) |
| `onedark` | `onedark` | Lalit Magant (http://github.com/tilal6991) | MIT (tinted-theming) |
| `tokyo-night-dark` | `tokyo-night-dark` | Michaël Ball | MIT (tinted-theming) |
| `catppuccin-mocha` | `catppuccin-mocha` | https://github.com/catppuccin/catppuccin | MIT (tinted-theming) |
| `github` | `github` | Tinted Theming (https://github.com/tinted-theming) | MIT (tinted-theming) |
| `monokai` | `monokai` | Wimer Hazenberg (http://www.monokai.nl) | MIT (tinted-theming) |
| `everforest-dark` | `everforest` ← | Sainnhe Park (https://github.com/sainnhe) | MIT (tinted-theming) |
| `kanagawa-wave` | `kanagawa` ← | Tommaso Laurenzi (https://github.com/rebelot) | MIT (tinted-theming) |
| `rose-pine` | `rose-pine` | Emilia Dunfelt <edun@dunfelt.se> | MIT (tinted-theming) |
| `catppuccin-macchiato` | `catppuccin-macchiato` | https://github.com/catppuccin/catppuccin | MIT (tinted-theming) |
| `gruvbox-light-hard` | `gruvbox-light-hard` | Dawid Kurek (dawikur@gmail.com), morhetz (https://github.com/morhetz/gruvbox) | MIT (tinted-theming) |
| `papercolor-light` | `papercolor-light` | Jon Leopard (http://github.com/jonleopard), Tinted Theming (https://github.com/tinted-theming), based on PaperColor Theme (https://github.com/NLKNguyen/papercolor-theme) | MIT (tinted-theming) |
| `one-light` | `one-light` | Daniel Pfeifer (http://github.com/purpleKarrot) | MIT (tinted-theming) |
| `ayu-light` | `ayu-light` | Tinted Theming (https://github.com/tinted-theming), Ayu Theme (https://github.com/ayu-theme) | MIT (tinted-theming) |
| `tokyo-night-light` | `tokyo-night-light` | Michaël Ball | MIT (tinted-theming) |
| `gruvbox-material-light-medium` | `gruvbox-material-light-medium` | Mayush Kumar (https://github.com/MayushKumar), sainnhe (https://github.com/sainnhe/gruvbox-material-vscode) | MIT (tinted-theming) |
| `ayu-dark` | `ayu-dark` | Tinted Theming (https://github.com/tinted-theming), Ayu Theme (https://github.com/ayu-theme) | MIT (tinted-theming) |
| `ayu-mirage` | `ayu-mirage` | Tinted Theming (https://github.com/tinted-theming), Ayu Theme (https://github.com/ayu-theme) | MIT (tinted-theming) |
| `zenburn` | `zenburn` | elnawe | MIT (tinted-theming) |
| `tokyo-night-storm` | `tokyo-night-storm` | Michaël Ball | MIT (tinted-theming) |
| `catppuccin-frappe` | `catppuccin-frappe` | https://github.com/catppuccin/catppuccin | MIT (tinted-theming) |
| `rose-pine-moon` | `rose-pine-moon` | Emilia Dunfelt <edun@dunfelt.se> | MIT (tinted-theming) |
| `tomorrow-night` | `tomorrow-night` | Chris Kempson (http://chriskempson.com) | MIT (tinted-theming) |
| `selenized-light` | `selenized-light` | Jan Warchol (https://github.com/jan-warchol/selenized) / adapted to base16 by ali | MIT (tinted-theming) |
| `selenized-white` | `selenized-white` | Jan Warchol (https://github.com/jan-warchol/selenized) / adapted to base16 by ali | MIT (tinted-theming) |
| `horizon-light` | `horizon-light` | Michaël Ball (http://github.com/michael-ball/) | MIT (tinted-theming) |
| `edge-dark` | `edge-dark` | cjayross (https://github.com/cjayross), Tinted Theming (https://github.com/tinted-theming) | MIT (tinted-theming) |
| `selenized-dark` | `selenized-dark` | Jan Warchol (https://github.com/jan-warchol/selenized) / adapted to base16 by ali | MIT (tinted-theming) |
| `horizon-dark` | `horizon-dark` | Michaël Ball (http://github.com/michael-ball/) | MIT (tinted-theming) |
| `primer-dark-dimmed` | `primer-dark-dimmed` | Jimmy Lin | MIT (tinted-theming) |
| `atelier-heath-light` | `atelier-heath-light` | Bram de Haan (http://atelierbramdehaan.nl) | MIT (tinted-theming) |
| `msc` | — | masc | 이 저장소의 MIT |
| `pc-tools` | — | masc | 이 저장소의 MIT |
| `cyber` | — | masc | 이 저장소의 MIT |
| `dungeon-gold` | — | masc | 이 저장소의 MIT |
| `norton` | — | masc | 이 저장소의 MIT |
| `msx` | — | masc | 이 저장소의 MIT |

## 여기 없는 것

### 그릴 수 없어서 뺀 것

대부분은 라이선스 문제가 아니라 masc 가 제대로 못 그려서 빠졌다. 2026-08-28 에
50개를 재서 12개를 뺐고, 뺀 이유와 측정값은 `bin/masc_tui_theme_catalog.ml` 맨 위
주석에 있다.

### 조건이 걸려서 뺀 것 — `material-palenight`

한 번 넣었다가 뺐다. 값 자체는 Nate Peterson 의 base16 이식본이고 tinted-theming
MIT 로 온다. 문제는 그 위쪽이다.

- 원본 [material-theme/vsc-material-theme](https://github.com/material-theme/vsc-material-theme)
  는 **라이선스 파일이 없다** (2026-08-28 GitHub API 확인, `license: null`).
- 원저자가 색과 이름의 재사용에 법적 조치를 예고했고, 그 때문에
  [원래 라이선스를 유지하는 별도 포크](https://github.com/t3dotgg/vsc-material-but-i-wont-sue-you)
  가 따로 존재한다.
- 원래 Apache-2.0 이었다가 git 히스토리가 지워졌다는 정황이 있다. 지워진 허가에
  기대는 자리에 서지 않는다.

색 목록 자체가 저작물인지는 다투어질 여지가 있고, 하위 이식본에는 MIT 표시가
붙어 있다. 그래도 뺀다. 남은 37개는 다툴 것 없는 허가가 있고, 하나를 지키자고
그 자리에 설 이유가 없다.

다시 넣으려면 원본 저장소에 허가가 다시 생겼는지부터 확인한다.

## 스킴을 추가할 때

1. `tinted-theming/schemes` 의 `base16/<이름>.yaml` 에서 값을 받는다. 손으로 적지 않는다.
2. `bin/masc_tui_theme_catalog.ml` 에 넣고 `test_tui_theme_contrast` 를 돌린다.
   떨어지면 넣지 않고, 측정값을 그 파일 주석에 적는다.
3. **이 문서의 표에 줄을 추가한다.** 카탈로그에 이름이 있는데 여기 없으면
   masc 가 남의 것을 싣고 이름을 안 밝히는 상태가 된다.
