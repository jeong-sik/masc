# TUI 프리셋이 쓰는 다른 프로젝트의 팔레트

`/theme` 으로 고르는 프리셋 14개 중 5개는 다른 프로젝트가 공개한 팔레트를 쓴다.
색 값은 `lib/masc_tui/core/theme.ml` 에 들어 있다.

| 프리셋 | 원본 | 저작권 표시 | 조건 |
|---|---|---|---|
| `solarized_dark` | [altercation/solarized](https://github.com/altercation/solarized) | Copyright (c) 2011 Ethan Schoonover | MIT |
| `nord` | [nordtheme/nord](https://github.com/nordtheme/nord) | Copyright (c) 2016-present Sven Greb <development@svengreb.de> (https://www.svengreb.de) | MIT |
| `dracula` | [dracula/dracula-theme](https://github.com/dracula/dracula-theme) | Copyright (c) 2023 Dracula Theme | MIT |
| `gruvbox_dark` | [morhetz/gruvbox](https://github.com/morhetz/gruvbox) | 저작권 줄 없음. `colors/gruvbox.vim` 머리말에 `Author: morhetz` | README 가 `MIT/X11` 이라고 밝힘 |
| `catppuccin_mocha` | [catppuccin/palette](https://github.com/catppuccin/palette) | Copyright (c) 2021 Catppuccin | MIT |

## 지켜야 할 것

MIT 은 **저작권 표시와 허가 문구를 함께 배포할 것**을 요구한다.
저작권 표시는 위 표에 적었고, 허가 문구는 아래 원문을 그대로 싣는다.
Solarized, Nord, Dracula, Catppuccin 의 `LICENSE` 허가 문구는 아래와 글자가 같다(줄바꿈과 공백만 다르다. 2026-11-25 에 GitHub API 로 내려받아 비교했다).

```
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

이름은 원래 이름 그대로 쓴다. `dracula` 를 `dracula` 라고 부르는 것은 그 팔레트를
가리키는 것이지 그 프로젝트가 masc 를 만들었다고 말하는 것이 아니다. 다만 어느
프로젝트든 이름 사용을 제한한다고 밝히면 그때 이름을 바꾸고 이 줄을 고친다.

Gruvbox 저장소에는 라이선스 파일이 없다(2026-11-25 GitHub API 확인).
README 의 `License` 절이 `MIT/X11` 이라고 밝혀서 넣었다.
원저자가 이 선언을 거두면 `gruvbox_dark` 를 뺀다.

## 값을 어디서 가져왔나

- 각 프로젝트의 원본 파일(Solarized README 의 색 표, Nord `src/nord.css`, Dracula README 의 색 표, `colors/gruvbox.vim`, Catppuccin `palette.json`)을 읽어서 뽑았다. 손으로 옮겨 적지 않았다.
- 팔레트에 없는 자리(`surface_1`, 선택 줄, 중간 밝기 글자 등)는 공개 색 두 개를 Oklab 에서 섞었다. `theme.ml` 의 줄마다 주석으로 원본 색 이름과 섞은 비율을 적었다.
- 대비가 AA(4.5:1)에 못 미치는 공개 색은 `build_theme` 가 밝기만 올린다. 화면에 보이는 색이 공개 값보다 밝을 수 있다.
