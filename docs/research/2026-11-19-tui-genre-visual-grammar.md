# btop 계열 TUI 여섯의 화면 문법과 MASC 경사 색 제안

운영자 요청(2026-11-19): btop 말고도 이 계열의 잘 만든 도구를 더 본다. 이 문서는
[btop 기록](2026-11-18-tui-btop-visual-grammar-and-idle-cost.md)에 이어 쓴다. 그 기록에 있는
것은 다시 적지 않는다. 그 기록과 어긋나는 것은 §1.4 에 모았다.

운영자 결정(2026-11-19)이 이 문서의 전제다.

- 막대와 그래프는 btop 처럼 경사 색으로 칠한다.
- 미터는 칸 위치로 경사 색을 고른다. 선언된 한도가 없는 미터도 그렇다.
- 그래프는 줄 높이나 값으로 경사 색을 고른다.
- 나란히 그린 계열은 계열마다 제 경사를 갖는다.
- 목록 줄 안의 작은 그래프는 흐리게 그린다.
- 이상(실패, 밀림)은 상태 색이 먼저다.

이 결정 전에 #53049 는 한도가 없는 막대와 그래프를 모두 기본 글자색으로 바꿨다. 운영자는
색으로 가르던 것이 사라졌다고 했다. 이 문서는 결정을 구현할 근거를 모은다. 경사의 멈춤점,
계열별 색, 256색·16색·색 없음으로 내려가는 법, 범례가 맞는 말을 하게 하는 법이다.
결정은 [한 화면 문법 RFC](../rfc/RFC-tui-one-screen-grammar.md)에 들어간다. 이 문서의 제안은
결정이 아니다. 제안에는 「제안」이라고 적는다.

## 1. 무엇을 왜 봤나

### 1.1 도구

| 도구 | 언어, 그리는 층 | 읽은 커밋 | 고른 이유 |
|---|---|---|---|
| btop | C++, escape 를 직접 쓴다 | [`5d03929`][bt-c] (2026-11-11) | 운영자가 든 기준이다. 이번에는 색 모델을 끝까지 읽었다 |
| bottom (`btm`) | Rust, ratatui | [`6e1c138`][bo-c] (2026-11-17) | 계열 하나에 색 하나를 모든 보기에서 쓴다 |
| htop | C, ncurses | [`21bbc80`][ht-c] (2026-11-13) | 색 없는 배색을 따로 둔다 |
| k9s | Go, tview·tcell | [`617476c`][k9-c] (2026-11-18) | 상태 역할 이름, 색각 이상 배색 |
| lazygit | Go, gocui·tcell | [`54cc6af`][lg-c] (2026-11-15) | 터미널 바탕색을 물어 색을 섞는다 |
| nvtop | C, ncurses | [`8455909`][nv-c] (2026-11-16) | 계열 여럿을 한 그래프에 겹치지 않게 그린다 |

날짜는 그 커밋의 커밋 날짜다.

### 1.2 축

여덟 축으로 읽었다: 색, 그래프, 미터, 테두리, 목록, 배치, 키 안내, 다시 그리기.

### 1.3 읽은 법

- 여섯 저장소를 얕게 받아 읽었다. 빌드하지 않았다. 돌리지 않았다. 화면을 찍지 않았다.
- 도구마다 한 번씩 읽고, 주장마다 `파일:줄` 을 남겼다.
- 색 모델의 주장은 받은 소스를 다시 열어 맞췄다. btop 기본 테마의 hex, 경사 만들기, 256색
  바꾸기, 16색 테마, 미터·그래프의 색 고르기, 목록 흐림이다.
- 다른 다섯 도구는 한 곳씩 맞췄다. bottom 점자 칸 겹침, htop 단색 막대 글자, k9s 고른 줄
  바탕, lazygit 작성자 색, nvtop 열 나누기다. 나머지는 읽기 기록의 인용을 옮겼다(§6).
- MASC 는 `866aefc` 를 읽었다.
- 경사 폭은 MASC 색 계산을 Python 으로 옮겨 53개 배색에서 쟀다(§3.8). btop 기본 테마의
  멈춤점도 같은 계산으로 쟀다(§3.1).
- 링크는 그 커밋에 고정한 GitHub 줄 주소다.

### 1.4 btop 기록 바로잡기

| btop 기록에 적은 것 | 이번에 본 것 | 근거 |
|---|---|---|
| truecolor 를 끄면 256색 6×6×6 정육면체로 바꾼다 | 정육면체만 쓰지 않는다. R·G·B 를 11 로 나눠 반올림한 값이 셋 다 같으면 회색 24단(232~255)을 쓴다. 정육면체만 말하는 것은 설정 설명이다 | [theme:155][bt-256], [config:80][bt-truecolor-doc] |
| 경사 색이 상태를 말한다. 막대 끝이 빨강에 닿으면 한도에 가깝다 | btop 경사는 두 종류다. cpu·process·temp 는 색상이 돈다. 메모리·디스크·네트워크 경사는 한 색상의 밝기만 오른다. 뒤쪽의 색은 상태가 아니다. 어느 계열인지와 얼마나 높은지를 말한다 | §3.1 |
| 한 줄 그래프는 열마다 그 값(0~100)의 색이다 | 한 칸에 표본 둘이 들어간다. 칸 색은 둘 중 큰 값의 색이다. 0~100 은 그 그래프 축 위의 자리다. 네트워크 축은 저절로 바뀌므로 한도가 아니다 | [draw:446][bt-graph], [collect:3068][bt-scale] |
| §3 「경사 미터는 선언된 한도가 있는 미터에만」 | 운영자 결정(2026-11-19)으로 바뀐다. 한도가 없는 미터는 계열 경사를 쓴다(§3.8) | — |
| 0 인 구간은 바닥에 점선으로 남는다 | 점선은 그래프가 그리지 않는다. 상자가 `⣀` 를 `inactive_fg` 로 먼저 깐다. 두 표본이 모두 0 인 칸은 그래프가 건너뛴다. 그래서 깔린 점선이 비친다 | [draw:917][bt-zero], [draw:446][bt-graph] |

## 2. 도구별 요약

| 축 | btop | bottom | htop | k9s | lazygit | nvtop |
|---|---|---|---|---|---|---|
| 색 | 계열마다 101칸 경사 표 [theme:306][bt-grad] | 계열마다 색 하나, 경사 없음 [style:112][bo-style] | 역할 × 배색 표, 단색도 한 배색 [CRT:128][ht-crt] | 상태 역할 8개, 경사 없음 [styles:146][k9-status] | 바탕색을 물어 선택 색을 섞음 [theme_config:31][lg-mix] | 그래프 안 자리마다 색, 8색 [setup:372][nv-slot] |
| 그래프 | 점자, 칸에 표본 둘, 줄 높이로 색 [draw:446][bt-graph] | 점자 선, 겹치면 나중 계열만 [grid:138][bo-grid] | 점자, 두 색, 합만 그림 [Meter:225][ht-graph] | 1/8 블록 막대, 1분 간격 [sparkline:84][k9-spark] | 시간 그래프 없음 [cell:11][lg-graph] | ACS 계단선, 계열이 열을 나눔 [plot:50][nv-plot] |
| 미터 | `■` 칸, 칸 위치로 색 [draw:398][bt-meter] | `[\|\|\|\| 42%]`, `█` 만 1/8 칸 [pipe_gauge:20][bo-gauge] | 쌓인 칸, 값 글자가 막대 위 [Meter:91][ht-bar] | 막대 없음, 70·90 문턱 색 [threshold:77][k9-thr] | 없음, 글자 수 ` 52 ` [commit_message:178][lg-len] | `\|` 채움, 두 겹 [interface:666][nv-meter] |
| 테두리 | 테두리에 탭·키·시계·위치 [draw:279][bt-box] | 제목만, 초점은 색 [canvas:58][bo-border] | 상자 없음, 머리 띠 [CRT:134][ht-panel] | `pods(ns)[n] </f>` 제목 문법 [table_helper:23][k9-title] | 모서리 자리 고정, `N of M` [gui:1498][lg-frame] | 그래프만 상자, 범례가 제목 [plot:126][nv-rect] |
| 목록 | 고른 줄에서 멀수록 흐림 [draw:2082][bt-procgrad] | 머리에 `▲▼`, 한쪽부터 열 배정 [column:172][bo-col] | 0·N/A 흐림, 자릿수 묶음 색 [Row:534][ht-shadow] | 고른 줄 바탕 = 줄 상태 색 [select_table:119][k9-sel] | 안 보이는 줄까지 열 폭 예약 [commits:228][lg-widths] | 정렬 열은 색만 다름 [interface:1690][nv-sort] |
| 배치 | % 격자, 작으면 필요 크기 표시 [btop:157][bt-small] | TOML 비율 행·열 [constants:196][bo-layout] | 머리 비율 틀 13개 [HeaderLayout:16][ht-layout] | 7줄 머리, 폭 반응 없음 [app:166][k9-header] | 이름 붙은 문턱, 상자 접기 [window_arrangement:414][lg-layout] | 순수 배치 함수 + 기하 시험 [interfaceTests:118][nv-test] |
| 키 안내 | 낱말 속 키 글자, 안 되면 회색 [draw:1918][bt-hint] | `?` 9구역 도움말 [help_dialog:47][bo-help] | 아래 기능 키 줄, 칸 폭 고정 [FunctionBar:92][ht-fbar] | 최대 6줄, 열 우선 메뉴 [menu:78][k9-menu] | 지금 쓸 만한 키만 색 [options_map:32][lg-options] | F키 줄, 모드마다 바뀜 [interface:2086][nv-keys] |
| 다시 그리기 | 그래프 두 위상, DEC 2026 [draw:493][bt-phase] | 사건으로만 그림 [lib:456][bo-event] | 선택만 움직이면 두 줄 [Panel:313][ht-repaint] | 2초마다 표 전체 재구성 [table:472][k9-update] | 내용만 바뀌면 배치 생략 [gui:1641][lg-flush] | 정적 틀은 배치 때 한 번 [interface:2354][nv-draw] |

## 3. 색

### 3.1 btop: 경사 표 하나를 세 가지로 읽는다

경사 표를 만드는 법([theme:306][bt-grad]):

- 테마 키가 `_start` 로 끝나면 101칸(0~100) 표를 미리 만든다.
- `_mid` 가 있으면 0~50 은 start→mid, 51~100 은 mid→end 다.
- `_mid` 가 비면 start→end 한 구간이다. `_end` 도 비면 101칸이 모두 start 색이다.
- 보간은 sRGB 채널 값을 정수로 나누는 직선이다. Oklab 같은 지각 공간을 쓰지 않는다.
- 칸 색은 표에서 찾는다. 프레임마다 계산하지 않는다.

같은 표를 세 가지로 읽는다.

| 그림 | 칸 색을 고르는 값 | 근거 |
|---|---|---|
| 미터 | 칸 i 의 자리 `round(i × 100 / 폭)` | [draw:398][bt-meter] |
| 여러 줄 그래프 | 그 줄의 높이. 줄 하나는 한 색이다 | [draw:446][bt-graph] |
| 한 줄 그래프 | 그 칸 표본 둘 중 큰 값 | [draw:446][bt-graph] |
| 미터 옆 수 | 그 값 자리의 색. 수와 막대 끝이 같은 색이다 | [draw:875][bt-readout] |

기본 테마의 멈춤점과 쓰는 곳([theme:68][bt-theme], [draw:1262][bt-mem], [draw:1303][bt-disk]).
Oklab 밝기(L)와 색상각(h)은 이 문서가 계산했다. 바탕은 기본 테마의 `main_bg` `#000000` 이다.

| 경사 | start | mid | end | L (start→mid→end) | h | 쓰는 곳 |
|---|---|---|---|---|---|---|
| cpu | `#77ca9b` | `#cbc06c` | `#dc4c4c` | 0.77→0.80→0.62 | 158→102→24 | CPU 미터·그래프, GPU, 배터리(뒤집음), ENC |
| process | `#80d0a3` | `#dcd179` | `#d45454` | 0.79→0.85→0.61 | 158→102→23 | 프로세스 값 열 |
| temp | `#4897d4` | `#5474e8` | `#ff40b6` | 0.65→0.60→0.69 | 245→269→348 | 온도 |
| free | `#384f21` | `#b5e685` | `#dcff85` | 0.40→0.87→0.95 | 131→131→123 | 메모리 free, 디스크 free·read |
| cached | `#163350` | `#74e6fc` | `#26c5ff` | 0.31→0.87→0.77 | 250→212→230 | 메모리 cached, GPU 전력 |
| available | `#4e3f0e` | `#ffd77a` | `#ffb814` | 0.37→0.89→0.83 | 91→87→80 | 메모리 available, 디스크 활동 |
| used | `#592b26` | `#d9626d` | `#ff4769` | 0.35→0.64→0.67 | 28→17→15 | 메모리 used, 디스크 used·write |
| download | `#291f75` | `#4f43a3` | `#b0a9de` | 0.31→0.45→0.76 | 280→284→291 | 받기 |
| upload | `#620665` | `#7d4180` | `#dcafde` | 0.35→0.47→0.81 | 327→325→325 | 보내기 |

표에서 읽는 것:

- 경사는 두 종류다. cpu·process·temp 는 밝기가 비슷하고 색상이 돈다. 초록→노랑→빨강은
  부하를 말한다.
- 나머지 여섯은 색상이 거의 그대로다. 세 멈춤점 사이에서 색상각이 38° 넘게 움직이지 않는다.
  밝기만 0.31~0.40 에서 0.67~0.95 로 오른다. 색상은 계열, 밝기는 높이를 말한다.
- 여섯의 start 는 검정 바탕에서 1.5:1~2.3:1 이다. 낮은 값은 바탕에 거의 묻힌다. 조용한
  구간이 조용하게 보이게 한 선택이다.
- swap 은 `swap_` 를 떼고 used·free 를 다시 쓴다([draw:1262][bt-mem]). 디스크 read 는 free,
  write 는 used, 활동은 available 이다([draw:1303][bt-disk]). 계열 수보다 경사 수가 적다.
- 상자마다 테두리 색이 다르다: cpu `#556d59`, mem `#6c6c4b`, net `#5c588d`, proc `#805252`.

다른 테마([nord][bt-nord], [dracula][bt-dracula], [greyscale][bt-greyscale], [paper][bt-paper]):

- nord 는 모든 계열이 한 경사 `#81A1C1`→`#88C0D0`→`#ECEFF4` 다. 상자 테두리도 한 색이다.
- dracula 의 cpu 는 `#bd93f9`→`#8be9fd`→`#50fa7b` 다. 빨강으로 끝나지 않는다.
- greyscale 은 `#50`→`#ff` 두 멈춤점 회색이다.
- paper 는 밝은 바탕(`#F2EEDE`)이다. 경사는 `#55`→`#00`→`#CC3E28` 이다.
- 색이 얼마나 많은 뜻을 싣는지는 테마가 정한다. 같은 프로그램이 nord 에서는 계열을 색으로
  가르지 않는다.

색 수가 모자랄 때:

- `truecolor=false` 면 표를 만들 때 256색으로 바꾼다. 회색이면 232~255, 아니면 정육면체다
  ([theme:155][bt-256]).
- 16색은 손으로 쓴 TTY 테마다([theme:103][bt-tty]). 계열 경사는 보통 항목→밝은 항목 두 띠다
  (`\x1b[34m`→`\x1b[94m`). cpu 는 밝은 초록→밝은 노랑→밝은 빨강 세 띠다. 띠 경계는 mid 가
  있으면 33·66, 없으면 50 이다([theme:366][bt-ttygrad]).
- TTY 모드는 그래프를 음영 글리프로, 모서리를 직각으로 바꾼다([btop:805][bt-ttymode]).
- `NO_COLOR` 와 색 없는 모드는 없다. 밝은·어두운 바탕을 알아내지 않는다.
- `theme_background=false` 면 바탕을 SGR 49 로 둔다([theme:248][bt-bg]).

### 3.2 bottom: 계열 하나에 색 하나

- 경사가 없다. 색은 크기가 아니라 어느 계열인지를 말한다([style:112][bo-style]).
- 테마는 이름 붙은 칸 약 30개다. 수가 정해지지 않은 계열(CPU 코어, 센서)은 색 목록이다.
  계열 번호를 목록 길이로 나눈 나머지로 색을 고른다([cpu_graph:137][bo-index]).
- 한 계열은 그래프 선, 범례 행, 미터에서 같은 색이다([cpu_basic:163][bo-same]).
- 기본 테마는 ANSI 이름 16개만 쓴다. 터미널 배색을 따른다([default:11][bo-default]).
- RX 는 RAM 과, TX 는 SWAP 과 같은 색이다. gruvbox·nord 테마도 이 짝을 지킨다.
- 두 계열이 한 점자 칸에 들어가면 나중 계열의 점만 남는다. 앞 계열의 점은 지운다
  ([grid:138][bo-grid]). CPU 그래프는 목록을 뒤집어 AVG 를 맨 위에 그린다.
- 상태 색은 두 곳뿐이다. 배터리(10% 미만, 50% 미만, 그 위)와 잘못된 검색어의 빨간 테두리다
  ([battery:150][bo-battery]).
- 색 값은 ANSI 이름, `#rgb`·`#rrggbb`, `r, g, b` 다. 256색 번호는 없다
  ([utils:42][bo-colorval]). 색 깊이를 알아내지 않는다. `NO_COLOR` 는 시험에만 있다.
- 밝은 테마는 따로 둔다. 바뀌는 칸만 덮고 나머지는 어두운 테마에서 물려받는다
  ([default:84][bo-light]).

### 3.3 htop: 역할 표와 색 없는 배색

- 색은 역할 약 118개를 배색 8개가 채우는 표다: `CRT_colorSchemes[scheme][role]`
  ([CRT:128][ht-crt]). 모든 그리기가 역할을 거친다.
- 색 없는 배색(Monochrome)이 표의 한 열이다. bold, dim, reverse 만 쓴다. 막대는 계열마다
  채움 글자를 바꾼다: `|#*@$%&.`([Meter:88][ht-mono]). 색 없이도 쌓인 계열이 갈린다.
- `has_colors()` 가 거짓이면 Monochrome 을 쓴다. 회색은 색이 8개보다 많으면 8번,
  아니면 굵은 0번이다. 검정 바탕은 터미널 기본 바탕(-1)이 된다([CRT:1350][ht-fallback]).
- Broken Gray 배색은 손으로 쓰지 않는다. Default 를 복사하고 굵은 회색만 흰색으로 바꾼다
  ([CRT:1203][ht-broken]).
- 계열마다 역할이 있다. CPU 는 nice 파랑, user 초록, system 빨강 같은 식이다
  ([CRT:180][ht-series]).
- 그래프는 두 색이다. 맨 위 줄과 나머지 줄이다. 계열은 합 하나로 그린다([Meter:225][ht-graph]).
- Load 막대는 용량에 견준 문턱으로 색을 바꾼다. 1.0 미만 초록, CPU 수 미만 노랑, 그 위
  빨강이다([LoadAverage:50][ht-load]).
- 도움말의 범례는 진짜 역할 색으로 그린다. 메모리 범례는 미터가 쓰는 표에서 만든다.
  범례와 막대가 어긋날 수 없다([Action:766][ht-legend]).

### 3.4 k9s: 상태 역할과 배색 파일

- 줄 상태 색은 닫힌 역할 8개다: new, modify, add, pending, error, highlight, kill,
  completed([styles:146][k9-status]).
- 배색(skin)은 YAML 이다. 앞에 팔레트를 anchor 로 적고 역할이 그것을 가리킨다. 기본 배색 위에
  덮으므로 일부만 쓴 배색도 된다([styles:785][k9-skin]).
- 색각 이상 배색은 역할은 그대로 두고 색만 바꾼다. modus-vivendi 의 add 는 `#44bc44` 다.
  deuteranopia 판은 add `#2fafff`, modify `#cabf00`, warn `#ffa00f` 다. tritanopia 판은
  modify `#feacd0`, warn `#ff7f86` 이다([deuteranopia][k9-cvd]).
- `--invert` 는 OkLch 에서 밝기를 뒤집는다(L → 1−L). 채도는 원래의 50% 이상을 지키고
  색상은 그대로 둔다. 상태 색이 뒤집은 뒤에도 같은 색으로 읽힌다([color:80][k9-invert]).
- 신호 약 열 가지가 배색을 거치지 않는다. 깜박 알림, 늘고 준 화살표, 문턱 색, Pulse 테두리,
  그래프 축(`#ff0066`)이다([sparkline:15][k9-bypass]). 밝은 배색이나 색각 이상 배색이 이
  신호에는 닿지 못한다. 모든 색을 역할로 거쳐야 하는 이유다.
- 경사가 없다. 그래프는 문턱 등급(0, 1, 2)으로 계열 색 목록에서 색을 고른다. 문턱을 넘으면
  그래프 전체 색이 바뀐다.

### 3.5 lazygit: 바탕을 물어 색을 섞는다

- 처음 그리기 전에 터미널에 색 구성(CSI `?996n`)과 바탕색(OSC 11)을 묻는다. DEC 2031 로 바뀜
  알림을 받고, 창이 초점을 받으면 다시 묻는다. Lab 밝기 0.5 미만이면 어두운 바탕이다
  ([color_scheme:56][lg-bgquery]).
- 선택 띠 색은 실제 바탕 hex 와 섞는다. 밝은 바탕에서 초점 띠는 바탕과 `#0064ff` 를 25%,
  초점 없는 띠는 `#000000` 을 15% 섞는다. 어두운 바탕의 초점 띠는 이름 색 `blue` 다
  ([theme_config:31][lg-mix]).
- 작성자 색은 이름 해시로 HSLuv 를 고른다. 밝기는 어두운 바탕 0.57~0.72, 밝은 바탕
  0.31~0.46 이다. 코드 주석은 흔한 바탕에서 4.5:1 을 넘는다고 적는다([authors:107][lg-author]).
- 늘 24비트로 쓰고 256색·16색 바꾸기는 tcell 에 맡긴다. `NO_COLOR` 면 색이 0개다
  ([gui:61][lg-downsample]).
- 상태 색은 ANSI 8색의 작은 낱말 모음이다. 커밋 해시는 안 올림 빨강, 올림 노랑, 합쳐짐
  초록이다([commits:537][lg-status]).

### 3.6 nvtop: 자리 색과 글자 범례

- 색은 그래프 안의 자리(0~3)에 붙는다. 장치나 지표에 붙지 않는다. 기본은 Cyan, Yellow,
  Green, Blue 다([setup:372][nv-slot]).
- 범례는 그래프 안에 계열마다 한 줄이다. 글자를 그 계열 색으로 쓰고 견본 기호는 없다. 오래된
  표본이 있는 쪽에 둔다([plot:110][nv-legend]).
- ANSI 8색과 터미널 기본 바탕(-1)만 쓴다. 색 없음은 전부 켜거나 전부 끈다
  ([interface:579][nv-colors]).
- 온도 색은 장치의 slowdown 온도에 견준다. 그 온도 5도 아래부터 노랑, 그 온도부터 빨강이다
  ([interface:731][nv-temp]).

### 3.7 MASC 지금

- 색은 읽는 사람의 터미널 배색에서 꺼낸다. OSC 10·11·4 로 물은 값이다. btop 처럼 hex 를
  박지 않는다.
- 상태 토큰은 다섯이다. Ok 밝은 초록, Warn 밝은 노랑, Bad 밝은 빨강, Info 밝은 청록,
  Muted 밝은 검정(`masc_tui_theme.ml:274`, `:318`).
- 배색 색이 바탕에 묻히면 Oklab 밝기만 옮겨 4.5:1 로 올린다(`masc_tui_color.ml`
  `lift_for_contrast`). 바탕은 둘이다: 페이지와 옆 창(`Page`, `Side_pane`).
- 색 깊이는 넷이다: `No_color`, `Colors_16`, `Colors_256`, `Truecolor`(`masc_tui_theme.ml:418`).
  256색은 xterm 기본 16~255 중 가장 가까운 칸이다. 회색 24단도 고른다
  (`masc_tui_terminal_palette.mli` `best_color_for_level`). btop 은 채널마다 반올림하고, MASC 는
  가장 가까운 칸을 찾는다.
- 선언된 한도 미터는 칸마다 success→warning(0~0.5), warning→danger(0.5~1)를 Oklab 으로
  잇는다. 16색은 50%·80% 띠, 색 없음은 기본 글자다(`masc_tui_theme.ml:450`, `:476`).
- 한도가 없는 미터(`Relative`)와 점자 그래프는 색이 없다(#53049, `masc_tui_chart.mli:51`).
- 종류 색 슬롯은 둘이다. `Slot_1` 밝은 파랑, `Slot_2` 밝은 자홍이다. 상태 토큰이 쓰지 않는
  색상은 이 둘뿐이다(`masc_tui_ansi.ml:148`, RFC-0431).
- 대비 시험은 실은 배색 53개(`config/themes/`)를 잰다(`test/test_tui_theme_contrast.ml`).
  한도 경사는 다섯 자리와 두 바탕에서 4.5:1 을 넘는다(`:761`). 두 슬롯은 Oklab 으로 0.023
  이상 떨어진다(`:417`).
- 실은 base16 배색은 보통 항목과 밝은 항목을 같은 칸으로 채운다. 4번과 12번이 모두
  `base0D` 다(`masc_tui_theme_catalog.ml:81`). 그래서 btop 식 「보통→밝은」 16색 두 띠는
  이 배색에서 한 색이 된다.

막대와 그래프를 그리는 곳:

| 곳 | 무엇 | 지금 | 제안 |
|---|---|---|---|
| `render_keepers.ml:3684` | 키퍼 상세의 컨텍스트 창 | 한도 경사 | 그대로 |
| `render_prim.ml:5048` | 턴의 컨텍스트 창 | 한도 경사 | 그대로 |
| `overview_providers.ml:216` | 계정 한도 창 | 한도 경사 | 그대로 |
| `render_metrics.ml:303`, `:539` | GC 점유(live / heap) | 기본 글자 | 계열 경사, 계열 1 |
| `render_metrics.ml:355` | 작업 완료 / 전체 | 기본 글자 | 계열 경사, 계열 1 |
| `render_metrics.ml:963` | 키퍼별 기억 수 / 전체 | 기본 글자 | 계열 경사, 계열 1 |
| `render.ml:245`, `:258` | 실행 / 띄울 수, 반응 여력 | 기본 글자, 부족분 수만 warning | 나란한 두 미터라 계열 1, 계열 2. 부족분은 이상 덧칠 |
| `usage_calls.ml:382` | 도구별 호출 수 / 최대 | 기본 글자 | 계열 경사, 계열 1 |
| `render_keepers.ml:857` | 키퍼 기억 칸(빈틈이면 warning) | 이상이면 warning | 이상 덧칠 먼저, 아니면 계열 1 |
| `render_prim.ml:3381` | 목표 완료 | 기본 글자 | 계열 경사, 계열 1 |
| `render_metrics.ml:824` | 완료 추세 점자 그래프 | 색 없음 | 한 줄 그래프, 값으로 계열 1 |
| `keeper_age_ladder.ml:155` | 키퍼 줄의 블록 sparkline | 색 없음 | 목록 줄 안이라 흐림 |

### 3.8 제안: MASC 색 문법

#### 경사 셋과 이상 덧칠 (제안)

| 이름 | 색 | 색이 말하는 것 | 쓰는 곳 |
|---|---|---|---|
| 부하 경사 | success → warning → danger | 상태: 한도에 얼마나 가까운가 | 선언된 한도가 있는 미터만 |
| 계열 경사 | 한 색상. 낮은 쪽 3:1, 높은 쪽 4.5:1 | 어느 계열인가, 축 위 어디인가 | 한도가 없는 미터, 그래프 |
| 흐림 | `recede` 한 색 | 줄에 딸린 보조 정보 | 목록 줄 안의 작은 그래프 |
| 이상 덧칠 | danger(실패), warning(밀림) | 상태 | 그 칸이나 그 시간 열. 위 셋보다 먼저 |

이렇게 나누는 이유:

- btop 도 두 종류를 쓴다(§3.1). 부하는 색상이 돌고, 계열은 밝기만 오른다.
- 모든 막대를 부하 경사로 칠하면 완료 100% 가 danger 색이 된다. 완료는 좋은 일이다.
- 계열 경사가 상태 색상을 쓰지 않아야 「이상은 상태 색이 먼저」가 뜻을 갖는다. 정상 칸이
  초록·노랑이면 노랑 이상 칸이 묻힌다.
- 한 색상의 밝기만 바꾸면 두 축이 섞이지 않는다. 색상은 어느 계열인지(bottom), 밝기는
  얼마나 높은지(btop 메모리·네트워크) 말한다.
- #53049 이전의 Progress 경사(파랑→청록→초록)는 "하는 중" 색 청록을 지나 진행 중으로
  읽혔다. 한 색상 경사는 그 길을 지나지 않는다.
- 계열 색상은 RFC-0431 슬롯 둘(파랑, 자홍)이다. 계열은 종류다. 정도가 아니다.

#### 멈춤점 (제안)

계열 색상의 배색 항목을 E, 바탕을 G 라 한다. 모두 지금 있는 함수다.

- 높은 쪽 = `lift_for_contrast ~background:G ~floor:4.5 E`.
- 낮은 쪽 = `recede_toward ~background:G ~floor:3.0 ~max_ratio:1.0 (높은 쪽)`.
- 사이 = 낮은 쪽에서 높은 쪽으로 `lerp_oklab`, 하한 3.0.
- 3.0 은 WCAG 2.1 SC 1.4.11(비텍스트 대비)의 하한이다. 그림의 칸은 글자가 아니다. 글자는
  4.5 를 지킨다.

MASC 색 계산을 Python 으로 옮겨 실은 배색 53개에서 쟀다. 바탕은 `base00`(페이지)다.
파랑은 `base0D`, 자홍은 `base0E`, danger 는 `base08` 을 4.5:1 로 올린 색이다. 거리는 Oklab
유클리드 거리다.

| 잰 것 | 최소(배색) | 중앙 | 최대 |
|---|---|---|---|
| 파랑 경사의 밝기 폭 ΔL | 0.095 (horizon-light) | 0.165 | 0.387 |
| 자홍 경사의 밝기 폭 ΔL | 0.096 (gruvbox-material-light-medium) | 0.151 | 0.333 |
| 높은 쪽끼리 거리(파랑·자홍) | 0.061 (tokyo-night-light) | 0.158 | 0.431 |
| 낮은 쪽끼리 거리(파랑·자홍) | 0.041 (kanagawa-wave) | 0.105 | 0.254 |
| 파랑 경사 양 끝 중 danger 에 가까운 쪽의 거리 | 0.040 (horizon-dark) | 0.269 | 0.374 |
| 자홍 경사 양 끝 중 danger 에 가까운 쪽의 거리 | 0.065 (cyber) | 0.188 | 0.302 |

- 53개 모두 3:1 낮은 쪽이 있었다. 높은 쪽은 모두 4.5:1 에 닿았다.
- 모든 거리가 지금 슬롯 시험의 하한 0.023 을 넘는다.
- MASC 경사는 btop 보다 좁다. btop download 의 ΔL 은 0.45, used 는 0.32 다. btop 은 낮은
  쪽을 1.5:1~2.3:1 까지 내리고, MASC 는 3:1 에서 멈추기 때문이다.
- ΔL 0.095 가 실제 터미널에서 높이 차로 보이는지는 재지 않았다(§6).

#### 칸이 경사의 어디를 쓰나 (제안)

| 그림 | 자리 t (0~1) |
|---|---|
| 미터 | 칸 i 는 `min((i+1)/폭, 값/최대)`. 지금 `limit_cell_colour` 와 같은 규칙이다 |
| 여러 줄 그래프 | 줄의 높이. 줄 하나는 한 색이다(btop) |
| 한 줄 그래프 | 그 칸 표본 둘 중 큰 값 / 축 최대 |
| 거울 그래프 | 위쪽과 아래쪽이 각자 제 계열이다. 자리는 가운데에서 먼 정도다 |
| 목록 줄 안의 작은 그래프 | 자리를 쓰지 않는다. `recede` 한 색이다 |
| 이상인 칸 | 자리를 쓰지 않는다. 상태 색이다 |

#### 그리는 곳이 고르는 타입 (제안 스케치)

```ocaml
type series = Series_1 | Series_2          (* RFC-0431 Slot_1, Slot_2 *)

type ink =
  | Load of Masc_tui_theme.limit_paint     (* 선언된 한도: success → warning → danger *)
  | Series of series                       (* 한 색상, 3:1 → 4.5:1 *)
  | Row_mini                               (* 목록 줄 안: recede 한 색 *)

type cell =
  | Position of float                      (* 0.0~1.0. ink 가 색을 고른다 *)
  | Anomaly of Masc_tui_theme.status       (* Bad 실패, Warn 밀림 *)
```

- `meter_scale` 의 `Relative` 는 `Series of series` 로 바뀐다. 계열을 고르지 않은 막대는
  만들 수 없다.
- 색은 `ink` 와 `cell` 을 `match` 하는 함수 하나에서만 나온다. `_ ->` 를 두지 않는다.
  경사를 더하면 컴파일러가 빠진 곳을 찾는다.
- `Anomaly` 는 자리보다 먼저다. 이상인 칸은 자리를 읽지 않는다.
- 그래프 표본 `sample` 은 읽기 실패를 `Absent` 로 합친다(`masc_tui_braille.mli:35`). 이상을
  칸에 칠하려면 표본이 이상을 따로 들고 와야 한다. 무엇이 「밀림」인지도 타입으로 정해야
  한다(§6).

#### 색 수마다 (제안)

| 깊이 | 부하 경사 | 계열 경사 | 흐림 | 이상 |
|---|---|---|---|---|
| truecolor | Oklab 으로 잇는다(지금) | Oklab 으로 잇는다, 3:1 → 4.5:1 | `recede` | `status_readable` |
| 256색 | 같은 색을 xterm 16~255 중 가장 가까운 칸으로(지금) | 같다 | 같다 | 같다 |
| 16색 | 50%·80% 세 띠(지금) | 계열의 밝은 항목 한 색 | `recede` 규칙대로 기본 글자 | 상태 항목 |
| 색 없음 | `■` 와 `·` 만 | `■` 와 `·` 만. 계열은 자리와 이름표가 가른다 | 기본 글자 | 기호와 낱말(§7.2), 거울의 아래쪽 |

16색에서 계열 경사를 띠로 나누지 않는 이유:

- btop 16색은 보통 항목→밝은 항목 두 띠다([theme:103][bt-tty]).
- MASC 가 싣는 base16 배색은 두 항목이 같은 칸이다(§3.7). 두 띠가 한 색이 된다.
- 다른 터미널에서는 보통 파랑이 어두운 바탕에서 안 읽힐 수 있다. xterm 기본 파랑
  `#0000ee` 는 검정 바탕에서 약 2.2:1 이다(계산값). 16색에서는 색을 올릴 수 없다.
- 그래서 16색 계열 경사는 한 색이다. 높이는 막대 길이와 수가 말한다. 망가지지 않고
  덜 보일 뿐이다.

색 없는 터미널에서 계열을 가르는 법:

- htop 은 계열마다 채움 글자를 바꾼다([Meter:88][ht-mono]). MASC 는 미터 하나에 계열
  하나라 글자를 바꿀 일이 없다.
- 짝을 이루는 두 계열은 거울의 위와 아래가 가른다. 셋째 계열부터는 줄을 나눈다. 자리와
  이름표가 색 없이 남는다.

#### 상태 색이 상태로 남게 (제안)

- 상태 색(success, warning, danger, info)은 상태, 부하 경사, 이상 덧칠에만 쓴다.
- 계열 경사는 슬롯 색상만 쓴다. 슬롯 둘은 상태 토큰과 겹치지 않는 색상이다.
- 부하 경사는 선언된 한도에만 쓴다. 초록→빨강 막대를 보면 한도라고 읽어도 된다.
- 정상 칸이 상태 색상을 쓰지 않으므로 이상 칸이 눈에 띈다.
- 한 그림에서 색으로 가르는 계열은 둘까지다. 셋째부터 줄을 나눠 따로 그린다. 상태 토큰이
  쓰지 않는 색상이 둘뿐이기 때문이다. nvtop 은 한 그래프에 넷까지 겹치고 그 이상을 막는다
  ([interface_options:72][nv-max]).
- htop 은 평범한 값(0, N/A, 기본값)을 흐리게 하고 강한 색을 이상에 남긴다
  ([Row:534][ht-shadow]). MASC 의 흐림은 이전 관측이다(RFC §6.4). 평범한 값 흐림은
  가져오지 않는다.

#### 범례가 맞는 말을 하게 (제안)

1. 그림과 범례는 같은 계열 목록에서 나온다. 범례만 쓰는 문자열을 두지 않는다. htop
   도움말 범례는 미터가 쓰는 표에서 만든다([Action:766][ht-legend]). bottom 은 그래프,
   범례 행, 미터가 같은 번호로 색을 고른다([cpu_basic:163][bo-same]).
2. 범례의 계열 이름은 그 계열의 높은 쪽 색으로 적는다. 견본 기호는 두지 않는다
   ([plot:110][nv-legend]).
3. 미터 옆 수는 부하 경사면 값이 든 띠의 색이다. 계열 경사면 계열의 높은 쪽 색이다. 수는
   글자라 4.5:1 을 지킨다. btop 은 수를 막대 끝과 같은 자리 색으로 칠한다
   ([draw:875][bt-readout]). MASC 계열 경사의 낮은 쪽은 3:1 이라 수에 쓰지 않는다.
4. 범례는 자리 낱말을 붙인다: `위 받기 · 아래 보내기`. 색이 없어도 맞다. k9s 는 모드를
   색, 아이콘, 앞 글자 셋으로 말한다([log_indicator:137][k9-toggle]).
5. 범례에 `▲` `▼` 를 쓰지 않는다. `▲` 는 주의다(RFC §7.2).
6. 대체 경로(배색 모름, 올림 끔, 16색)에서도 그림과 범례는 같은 함수에서 색을 받는다.
   그래서 같이 바뀐다.
7. `?` 도움말의 색 설명은 `ink` variant 에서 만든다.
8. 결정 시험 하나: 범례의 계열 집합과 그린 계열 집합이 같다.

#### 대비를 재는 법 (제안)

`test_tui_theme_contrast.ml` 에 더한다. 지금 한도 경사 시험(`:761`)과 같은 틀이다.

- 실은 배색 전부 × 두 바탕(페이지, 옆 창) × 다섯 자리(0, 0.25, 0.5, 0.75, 1).
- 계열 경사의 모든 칸은 3:1 이상이다. 높은 쪽과 수는 4.5:1 이상이다.
- 같은 자리의 두 계열은 Oklab 으로 0.023 이상 떨어진다(지금 슬롯 하한).
- 계열 경사의 모든 자리는 4.5:1 로 올린 danger 와 0.023 이상 떨어진다.
- 색각 이상 흉내(`simulate_deficiency`)에서 계열과 danger 의 거리를 잰다. 하한은 잰 뒤
  정한다.
- `NO_COLOR` 면 모든 칸이 빈 문자열이다.
- 0.023 은 슬롯 시험에서 빌린 값이다. 계열 경사에 맞는 값인지는 재고 나서 정한다.

## 4. 그래프·미터·테두리·목록·배치·키·다시 그리기

### 4.1 그래프

| 도구에서 본 것 | MASC 지금 | 가져오나 | 이유 |
|---|---|---|---|
| 줄 높이·값으로 경사 [draw:446][bt-graph] | 색 없음 | 가져온다(§3.8) | 운영자 결정 |
| 바닥 점선을 먼저 깔고 0 칸은 건너뜀 [draw:917][bt-zero] | `Zero` 가 `⣀` 를 그린다 | 이미 있다 | — |
| 0.1~5% 를 5 로 올려 작은 값이 보임 [draw:2169][bt-procfloor] | `Value` 는 바닥보다 한 점 이상 위 | 이미 있다 | — |
| 축 최대는 범위 밖 표본이 5번 쌓여야 바뀜. 올릴 때 평균 ×1.3, 내릴 때 ×3, 하한 10 KiB [collect:3068][bt-scale] | 창 안 최대(`graph_maximum`) | 제안: 가져온다 | 축 숫자가 표본마다 바뀌면 글자가 흔들린다. 다시 그리는 일도 는다(RFC §8) |
| 짝 계열의 축을 맞추는 sync [collect:3068][bt-scale] | 거울은 한 축 | 이미 있다 | — |
| 축 최대 캐시, 새 표본만 훑음 [auto_y:13][bo-autoy] | 그릴 때마다 전부 훑음 | 지금은 가져오지 않는다 | btop 기록 §4 에서 build p50 은 0.26~0.67 ms 다. 병목이 아니다 |
| 겹친 점자 칸은 나중 계열만 [grid:138][bo-grid] | 겹쳐 그리지 않는다(거울) | 가져오지 않는다 | 색 있는 계열을 둘로 묶고 거울과 줄 나눔으로 겹침을 없앤다 |
| 계열마다 열을 나눔, 움직인 계열이 교차점을 가짐 [plot:50][nv-plot], [plot:63][nv-cross] | — | 가져오지 않는다 | 시간 해상도가 계열 수만큼 준다 |
| 시간 축에 `60s`·`0s` 두 낱말, 확대 뒤 5초만 보임 [base:111][bo-axis] | 창 길이를 적지 않는다 | 열린 것 | btop 도 적지 않는다. 적을 자리가 축 열 아래뿐이다 |
| 표본 없음과 0 이 같음(nvtop 결함) [interface:2137][nv-zero] | `Unread`·`Absent`·`Zero` 가 다르다 | 지금이 낫다 | — |
| 목록 줄 작은 그래프 5칸, 한 색 [draw:2058][bt-procgraph] | 블록 sparkline, 색 없음 | 가져온다: `recede` 한 색, 이상만 상태 색 | 운영자 결정 |

### 4.2 미터

| 도구에서 본 것 | MASC 지금 | 가져오나 | 이유 |
|---|---|---|---|
| 칸 위치로 경사 [draw:398][bt-meter] | 한도 미터만 | 가져온다(§3.8) | 운영자 결정 |
| 수가 막대 끝과 같은 색 [draw:875][bt-readout] | 수는 기본 글자. 부족분만 warning | 가져온다(§3.8 범례 3) | 수와 막대가 같은 말을 한다 |
| 폭 문턱을 묶음의 첫 칸이 정함. 12칸 이상 이름·막대·수, 10~11칸 수만 [cpu_basic:102][bo-gaugecut] | 카드 폭이 좁으면 미터 대신 글 한 줄(`render_metrics.ml:298`) | 제안: 가져온다 | 한 카드의 미터들이 같은 모양으로 줄어든다. MASC 는 수를 늘 남긴다(RFC §5.6) |
| 미터가 100% 의 뜻을 선언 [Meter.h:81][ht-total] | `meter_scale` | 이미 있다 | — |
| 두 겹 미터(쓴 것 안의 유효분) [interface:684][nv-twolayer] | 없음 | 열린 것 | 컨텍스트 창 안의 캐시 토큰 같은 곳에 맞을 수 있다. 확인 필요 |
| 한 칸이 안 되는 값은 0칸 [draw:398][bt-meter] | 0 보다 크면 한 칸 이상(`bar_filled_cells`) | 가져오지 않는다 | 작은 값이 0 으로 보인다(RFC §5.6) |
| `█` 의 1/8 칸 [pipe_gauge:20][bo-gauge] | `■` 온칸 | 가져오지 않는다 | btop 도 온칸이다. `■` 와 `·` 가 같은 칸 수를 쓴다 |

### 4.3 테두리

| 도구에서 본 것 | MASC 지금 | 가져오나 | 이유 |
|---|---|---|---|
| 모서리 자리 고정: 왼쪽 위 이름, 오른쪽 위 지금 상태, 오른쪽 아래 `N of M` [gui:1498][lg-frame] | 위에 이름·상태·개수, 아래에 `외 N`(RFC §2) | 이미 비슷하다 | — |
| 한 줄로 눌린 상자 `╶─이름──3 of 9─╴` [gui:1465][lg-squash] | 없음 | 제안: 가져온다 | 높이가 모자란 카드가 사라지지 않는다. 이름과 개수가 남는다 |
| 스크롤 막대가 오른쪽 테두리 자체. 끝에서만 바닥에 닿음 [scrollbar:7][lg-scroll] | 카드 오른쪽 테두리 막대(RFC §2) | 계산식을 가져온다 | 막대가 바닥에 닿으면 정말 끝이다 |
| 초점은 옆 테두리만 생기고 내용은 안 움직임 [drawing_utils:33][bo-basic-border] | `border.focused` 와 다른 기호 | 이미 비슷하다 | — |
| 초점을 색으로만 [canvas:58][bo-border] | — | 가져오지 않는다 | 색 없이 안 보인다 |
| 위첨자 상자 번호 [draw:279][bt-box] | #53050 이 지웠다 | 가져오지 않는다 | btop 기록 §3 |
| 상자마다 테두리 색 [theme:62][bt-theme] | 카드 테두리는 한 색 | 가져오지 않는다 | 카드는 이름이 가른다. 테두리 색은 초점이 쓴다 |

### 4.4 목록

| 도구에서 본 것 | MASC 지금 | 가져오나 | 이유 |
|---|---|---|---|
| 고른 줄 바탕 = 그 줄의 상태 색 [select_table:119][k9-sel] | 고른 줄은 띠이고 안의 색을 지운다(`strip_sgr`) | 열린 것 | 고른 줄의 상태 색이 사라진다. 기호와 낱말은 남는다 |
| 정렬 방향: bottom `▲▼` [sortable:115][bo-sort], htop `△▽` [Table:445][ht-sortmark] | 정하지 않았다 | 제안: `▲` 를 피한다 | `▲` 는 주의다(RFC §7.2) |
| 평범한 값 흐림 [Row:534][ht-shadow] | 흐림 = 이전 관측(RFC §6.4) | 가져오지 않는다 | 뜻이 섞인다 |
| 자릿수 묶음마다 색 [Row:225][ht-digits] | 쉼표(RFC §6.3) | 가져오지 않는다 | 색이 크기를 말하게 된다. 계열 색과 겹친다 |
| 키를 누른 뒤 5틱 동안 정렬 멈춤 [ScreenManager:136][ht-sortpause] | 정렬 키가 바뀔 때만 순서가 바뀐다(RFC §8) | 이미 더 강하다 | — |
| 사라진 줄 5초 빨강, 새 줄 초록 [Row:49][ht-tomb]. 바뀐 칸 한 틱 `↑↓Δ` [table_data:426][k9-delta] | 없음 | 가져오지 않는다 | 정상 변화를 상태 색으로 칠한다. 이상 덧칠 규칙과 어긋난다 |
| 불러온 줄 전체로 열 폭을 잡음 [commits:228][lg-widths] | 같다(RFC §8) | 이미 있다 | — |
| 초점 창 띠와 다른 창 흐린 띠 [view:1062][lg-select] | 같다(RFC §5.1) | 이미 있다 | — |
| 고른 줄에서 멀수록 흐림 [draw:2082][bt-procgrad] | 하지 않는다(RFC §12) | 그대로 | btop 기록 §3 |

### 4.5 배치

| 도구에서 본 것 | MASC 지금 | 가져오나 | 이유 |
|---|---|---|---|
| 배치가 순수 함수. 겹침 없음·화면 안·비지 않음을 시험하고 과거 버그 크기를 고정 [interfaceTests:118][nv-test] | 없음 | 제안: 가져온다 | 문구가 아니라 결정을 본다(RFC §10). 평가 기준을 먼저 고정한다 |
| 너무 작으면 지금 크기와 필요한 크기를 적은 화면 [btop:157][bt-small]. lazygit 은 `Not enough space` 화면 [window_arrangement:414][lg-layout] | RFC-0459 §4.1 폭 기준 | 제안: 바닥 화면을 가져온다 | 무엇이 왜 빠졌는지 말한다 |
| 생겼다 사라지는 줄은 30초 쉰 뒤에만 숨김 [interface:777][nv-hide]. 옵션이 같으면 줄은 늘기만 [interface:939][nv-jitter] | 그린 줄 수를 붙듦(RFC §8) | 이미 비슷하다 | — |
| 프리셋 [config:92][bt-preset] | 보기(`v`) | 가져오지 않는다 | 보기가 같은 일을 한다 |

### 4.6 키 안내

| 도구에서 본 것 | MASC 지금 | 가져오나 | 이유 |
|---|---|---|---|
| 낱말 속 키 글자만 다른 색 [draw:1918][bt-hint] | 구역 5 의 `c 대화` | 가져오지 않는다 | 키가 낱말 앞에 따로 있다. 한글 낱말 안에는 영문 키 글자가 없다 |
| 지금 안 되는 키는 회색으로 자리를 지킴 [draw:1947][bt-grey]. htop 은 읽기 전용에서 빈칸 [FunctionBar:92][ht-fbar]. k9s 는 지움 [action:159][k9-ro] | 되는 키만 적는다(RFC §2) | 제안: 흐린 글자로 남긴다 | 키가 사라졌다 생기면 줄이 흔들린다(RFC §8). 왜 안 되는지는 동작 창이 말한다 |
| 지금 누를 만한 키만 색 [options_map:32][lg-options] | 키 글자에 색 없음(RFC §7.3) | 가져오지 않는다 | 색은 상태와 계열에 쓴다 |
| 모드 이름은 한 곳, 옆에 `(Reset)` [mode_helper:50][lg-mode] | 구역 2 의 경로와 보기 | 이미 비슷하다 | — |

### 4.7 다시 그리기

| 도구에서 본 것 | MASC 지금 | 가져오나 | 이유 |
|---|---|---|---|
| 내용만 바뀐 묶음은 배치를 건너뜀 [gui:1641][lg-flush] | 보이는 값이 바뀔 때만 그린다(RFC §8) | 재고 나서 | btop 기록 §4 에서 CPU 는 그리기보다 JSON 해석이 쓴다 |
| 스피너는 일이 있을 때만 돌고 벽시계로 위상을 맞춤 [inline_status:113][lg-spinner] | `◐` 는 멈춰 있다(#53121) | 이미 더 조용하다 | — |
| 그래프 두 위상을 미리 그리고 표본마다 한 칸 [draw:493][bt-phase]. 미터 문자열 101개 캐시 [draw:398][bt-meter] | 그릴 때마다 만든다 | 지금은 가져오지 않는다 | build p50 0.26~0.67 ms 다 |
| 키로 다시 그려도 그래프 역사가 안 나아감 [draw:493][bt-phase] | 엔진 그래프는 2초 표본(RFC §5.6) | 확인 필요 | 키를 눌러 다시 그릴 때 표본을 더 모으는지 보지 않았다 |
| 선택만 움직이면 두 줄만 [Panel:313][ht-repaint] | 바뀐 줄만 쓴다(btop 기록 §4) | 이미 비슷하다 | — |
| DEC 2026 동기 출력 [tools:755][bt-sync] | 쓴다(`masc_tui_frame_presenter.ml:41`) | 이미 있다 | — |
| 2초마다 표 전체를 다시 만듦 [table:472][k9-update] | — | 가져오지 않는다 | 바뀐 것이 없어도 비용을 쓴다 |
| 터미널 바탕이 바뀌면 DEC 2031 알림으로 색을 다시 셈 [color_scheme:56][lg-bgquery] | OSC 응답 세대 번호로 색을 다시 셈(`masc_tui_ansi.ml` `Theme`) | 열린 것 | 터미널 테마를 바꿨을 때 MASC 가 다시 묻는지 보지 않았다 |

## 5. RFC 에 바꿀 것

[한 화면 문법 RFC](../rfc/RFC-tui-one-screen-grammar.md)에 넣을 글이다. RFC 의 말투로 썼다.
아래는 제안이다.

### 5.1 §0 결정 10

지금:

> 10. 그래프는 점자로 그린다. 선언된 한도가 있는 미터만 칸마다 색이 다르다. (§5.6, §7.3)

바꿀 글:

> 10. 그래프는 점자로 그린다. 막대와 그래프는 경사로 칠한다. 상태 색 경사는 선언된 한도가
>     있는 미터만 쓴다. 이상은 상태 색이 먼저다. (§5.6, §7.3)

### 5.2 §5.6 그림에 더할 것

- 짝을 이루는 두 값의 거울에서 위쪽은 계열 1, 아래쪽은 계열 2 다. 아래쪽이 실패면 계열
  대신 `status.danger` 다.
- 목록 줄 안의 작은 그래프는 흐린 글자 한 색이다. 이상인 칸만 상태 색이다.
- 축의 최대는 범위를 벗어난 표본이 다섯 번 쌓일 때만 바꾼다. 올릴 때는 최근 다섯 표본
  평균의 1.3배, 내릴 때는 3배다(btop). 값은 화면을 찍어 보고 정한다.
- 한 카드의 미터들은 폭에 따라 같이 줄어든다. 12칸 이상이면 이름·막대·수, 10~11칸이면
  막대를 빼고 이름과 수다. 묶음의 첫 미터가 정한다(bottom).

### 5.3 §7.3 색 (전체를 바꾼다)

> ### 7.3 색
>
> - 색은 세 가지를 말한다: 상태, 계열, 축 위의 자리. 상태 색(`status.success`·`warning`·
>   `danger`·`info`)은 상태, 선언된 한도, 이상에만 쓴다. 색 없이도 기호, 낱말, 자리로
>   읽힌다(RFC-0459 §3).
> - `status.info` 는 "하는 중"과 초점에만 쓴다. 구역 머리, 키 글자, 모델 이름, 그림의
>   계열에 쓰지 않는다.
> - 막대와 그래프는 경사로 칠한다. 경사는 셋이다. 그리는 곳이 타입으로 하나를 고른다.
>
>   | 경사 | 색 | 쓰는 곳 |
>   |---|---|---|
>   | 부하 | `status.success` → `status.warning` → `status.danger` | 선언된 한도가 있는 미터 |
>   | 계열 | 한 색상. 낮은 쪽은 바탕 쪽으로 물려 3:1, 높은 쪽은 4.5:1 | 한도가 없는 미터, 그래프 |
>   | 흐림 | `text.subtle` 한 색 | 목록 줄 안의 작은 그래프 |
>
> - 이상(실패, 밀림)인 칸은 경사 대신 상태 색이다. 실패는 `status.danger`, 밀림은
>   `status.warning` 이다. 정상 칸은 상태 색상을 쓰지 않는다. 키퍼 pulse 그림의 정상 턴도
>   그렇다.
> - 칸이 경사의 어디를 쓰는지: 미터는 칸 위치, 여러 줄 그래프는 줄 높이, 한 줄 그래프는
>   그 칸 두 표본 중 큰 값이다.
> - 부하 경사의 칸 위치는 한도에 대한 비율이다. 0 에 가까운 칸은 `status.success`, 가운데는
>   `status.warning`, 한도에 가까운 칸은 `status.danger` 다. 막대 끝의 색이 한도에 얼마나
>   가까운지 말하므로 이 색은 상태다.
> - 선언된 한도는 설정이나 provider 가 알려 준 상한이다. 닿으면 거절이나 대기가 생긴다. 계정
>   한도(쓴 양 / 한도)와 컨텍스트 창(쓴 토큰 / 최대)이 그렇다.
> - 완료 비율, 전체에서 차지하는 몫, 가장 큰 값과 견준 크기, 한도인지 확인되지 않은 막대는
>   계열 경사다. 계열 경사의 색은 상태가 아니다. 어느 계열인지와 축 위 어디인지를 말한다.
> - 계열 색상은 RFC-0431 의 슬롯 둘이다. 상태 토큰이 쓰지 않는 색상은 이 둘뿐이다. 나란히
>   그린 계열은 계열마다 슬롯 하나를 갖는다. 한 그림에서 색으로 가르는 계열은 둘까지다.
>   셋째부터는 줄을 나눠 따로 그리고 이름표를 단다.
> - 색 수에 따라:
>
>   | 깊이 | 부하 | 계열 | 흐림 |
>   |---|---|---|---|
>   | truecolor, 256색 | Oklab 으로 이어 칠한다. 256색은 가장 가까운 칸이다 | 같다 | `text.subtle` |
>   | 16색 | 칸 위치 50% 미만 success, 80% 미만 warning, 그 위 danger | 계열의 밝은 항목 한 색 | 기본 글자 |
>   | 색 없음 | 기본 글자 | 기본 글자. 계열은 자리와 이름표가 가른다 | 기본 글자 |
>
> - 칸마다 다른 색은 수를 대신하지 않는다. 미터 옆에는 늘 수를 적는다. 수는 부하 경사면
>   값이 든 띠의 색, 계열 경사면 계열의 높은 쪽 색이다.
> - 범례는 그림과 같은 계열 목록에서 만든다. 계열 이름은 그 계열의 높은 쪽 색으로 적고
>   자리 낱말(`위`, `아래`)을 붙인다. 견본 기호를 두지 않는다. `?` 도움말의 색 설명도 같은
>   목록에서 만든다.
> - 대비는 `test_tui_theme_contrast` 가 잰다. 실은 배색 전부, 두 바탕, 다섯 자리에서 계열
>   경사의 칸은 3:1, 높은 쪽과 수는 4.5:1 을 넘는다. 같은 자리의 두 계열, 계열과
>   `status.danger` 는 Oklab 으로 0.023 이상 떨어진다.
> - 굵은 글자는 고른 것, 화면 이름, 카드 이름에만 쓴다. 한 열 전체나 합계 칸을 굵게 하지
>   않는다.
> - (채팅 아래 정보 묶음의 종류 색 문단은 지금 글 그대로 둔다.)

### 5.4 §9 넣는 순서 8 에 더할 것

- 경사 타입(`ink`, `cell`)과 대비 시험을 먼저 넣는다. 그 층에서 `meter_scale` 의 `Relative`
  를 지운다. 그다음 그리는 곳을 화면 하나씩 옮긴다.

### 5.5 §12 에 더할 것

하지 않는 것:

- 정상 변화를 상태 색으로 칠하는 것(htop 새 줄·지운 줄, k9s 바뀐 칸). 상태 색은 이상에 쓴다.
- 평범한 값을 흐리게 하는 것(htop shadow). 흐림은 이전 관측이다(§6.4).

열린 것:

- 셋째 계열부터 줄을 나누는 대신 색을 더 쓸지. 상태와 겹치지 않는 슬롯은 둘뿐이다.
- 16색에서 계열 경사를 두 띠로 나눌지. 보통 항목과 밝은 항목이 다른 터미널에서만 뜻이 있다.
- 3:1 이 점자 점처럼 가는 글리프에 충분한지.
- 고른 줄이 그 줄의 상태 색을 남길지(k9s).
- 정렬 방향 기호. `▲` 는 주의라 쓰지 않는다.
- 그래프의 시간 창 길이를 적을지.
- 「밀림」을 무엇으로 정할지, 실패를 그래프 칸에 칠하려면 표본이 무엇을 들고 와야 하는지.

## 6. 확인하지 못한 것

- 여섯 도구 모두 빌드하거나 돌리지 않았다. 화면을 찍지 않았다. 주장은 소스에서 왔다.
- 다시 열어 맞춘 것은 btop 색 모델과 다른 도구 한 곳씩이다(§1.3). 나머지 인용은 읽기 기록을
  옮겼다. 줄 번호가 한두 줄 어긋날 수 있다.
- §3.8 의 수치는 `masc_tui_color.ml` 을 Python 으로 옮겨 계산한 추정이다. OCaml 코드를 돌린
  값이 아니다. 계산 스크립트는 저장소에 넣지 않았다. 같은 값은 §5.3 의 대비 시험이 재야 한다.
- 그 계산은 페이지 바탕만 쟀다. 옆 창 바탕, 색각 이상 흉내, 실제 터미널 배색은 재지 않았다.
- 배색 항목 대응(파랑 `base0D`, 자홍 `base0E`, 빨강 `base08`)은 `masc_tui_theme_catalog.ml` 의
  표를 따랐다. 자기 배색을 쓰는 터미널에서는 값이 다르다.
- 3:1 은 WCAG 2.1 SC 1.4.11 의 값이다. 점자 점처럼 가는 글리프에서 3:1 이 충분한지 모른다.
  ΔL 0.095 가 높이 차로 보이는지도 모른다. 화면을 찍어 봐야 한다.
- 「한 그림에 색 있는 계열 둘」은 제안이다. 운영자 결정이 필요하다.
- lazygit 작성자 색이 4.5:1 을 넘는다는 것은 코드 주석이다. 재지 않았다.
- k9s 의 두 가지는 읽기로 짐작했다. 일부만 쓴 배색에 `--invert` 를 걸면 물려받은 칸이 두 번
  뒤집힌다는 것, 접힌 머리의 MEM 화살표가 CPU 이전 값과 비교한다는 것이다.
- bottom 에서 표본이 빠진 자리가 선을 끊는지는 짐작이다. `timeless` crate 를 읽지 않았다.
- MASC 가 터미널 테마 바뀜(DEC 2031)을 받는지, 키를 눌러 다시 그릴 때 엔진 그래프 표본이
  느는지는 보지 않았다.
- 키퍼 pulse 그림이 지금도 정상 턴을 노랑으로 그리는지 보지 않았다. RFC 지금 글을 따랐다.

[bt-c]: https://github.com/aristocratos/btop/tree/5d03929a45e0720a4c8e2d189360ff1eb9ce1731
[bt-theme]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_theme.cpp#L52-L101
[bt-grad]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_theme.cpp#L305-L363
[bt-256]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_theme.cpp#L154-L165
[bt-truecolor-doc]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_config.cpp#L80
[bt-tty]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_theme.cpp#L103-L152
[bt-ttygrad]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_theme.cpp#L366-L386
[bt-ttymode]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop.cpp#L805-L822
[bt-bg]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_theme.cpp#L248-L252
[bt-meter]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L398-L419
[bt-graph]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L446-L486
[bt-readout]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L875-L876
[bt-mem]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L1262-L1278
[bt-disk]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L1303-L1326
[bt-zero]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L917-L922
[bt-scale]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/linux/btop_collect.cpp#L3068-L3090
[bt-procgraph]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L2058-L2070
[bt-procfloor]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L2169
[bt-box]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L279-L331
[bt-hint]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L1918-L1944
[bt-grey]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L1947-L1980
[bt-procgrad]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L2082-L2106
[bt-small]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop.cpp#L157-L197
[bt-preset]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_config.cpp#L92-L95
[bt-phase]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_draw.cpp#L493-L536
[bt-sync]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/src/btop_tools.cpp#L755-L756
[bt-nord]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/themes/nord.theme#L37-L59
[bt-dracula]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/themes/dracula.theme#L32-L54
[bt-greyscale]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/themes/greyscale.theme#L57-L59
[bt-paper]: https://github.com/aristocratos/btop/blob/5d03929a45e0720a4c8e2d189360ff1eb9ce1731/themes/paper.theme#L7-L53

[bo-c]: https://github.com/ClementTsang/bottom/tree/6e1c1385d82285a35c0d75c95bfab243d2c850c1
[bo-style]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/options/config/style.rs#L112-L149
[bo-index]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/widgets/cpu_graph.rs#L137-L142
[bo-same]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/widgets/cpu_basic.rs#L163-L170
[bo-default]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/options/config/style/themes/default.rs#L11-L81
[bo-light]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/options/config/style/themes/default.rs#L84-L131
[bo-grid]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/components/time_series/vendored/grid.rs#L138-L160
[bo-battery]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/widgets/battery_display.rs#L150-L158
[bo-colorval]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/options/config/style/utils.rs#L42-L54
[bo-gauge]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/components/pipe_gauge.rs#L20-L52
[bo-gaugecut]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/widgets/cpu_basic.rs#L102-L114
[bo-axis]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/components/time_series/base.rs#L111-L132
[bo-autoy]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/components/time_series/auto_y.rs#L13-L92
[bo-border]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas.rs#L58-L65
[bo-basic-border]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/drawing_utils.rs#L33-L51
[bo-col]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/components/data_table/column.rs#L172-L255
[bo-sort]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/components/data_table/sortable.rs#L115-L138
[bo-layout]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/constants.rs#L196-L219
[bo-help]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/canvas/dialogs/help_dialog.rs#L47-L117
[bo-event]: https://github.com/ClementTsang/bottom/blob/6e1c1385d82285a35c0d75c95bfab243d2c850c1/src/lib.rs#L456-L530

[ht-c]: https://github.com/htop-dev/htop/tree/21bbc80c7811149ee33f449748addf23740c7b9f
[ht-crt]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/CRT.c#L128-L136
[ht-panel]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/CRT.c#L134-L139
[ht-series]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/CRT.c#L180-L212
[ht-broken]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/CRT.c#L1203-L1206
[ht-fallback]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/CRT.c#L1350-L1373
[ht-mono]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Meter.c#L88-L173
[ht-bar]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Meter.c#L91-L196
[ht-graph]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Meter.c#L225-L232
[ht-total]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Meter.h#L81-L85
[ht-load]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/LoadAverageMeter.c#L50-L57
[ht-legend]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Action.c#L766-L827
[ht-shadow]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Row.c#L534-L556
[ht-digits]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Row.c#L225-L325
[ht-tomb]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Row.c#L49-L82
[ht-fbar]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/FunctionBar.c#L92-L105
[ht-sortpause]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/ScreenManager.c#L136-L141
[ht-sortmark]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Table.c#L445-L470
[ht-repaint]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/Panel.c#L313-L363
[ht-layout]: https://github.com/htop-dev/htop/blob/21bbc80c7811149ee33f449748addf23740c7b9f/HeaderLayout.h#L16-L50

[k9-c]: https://github.com/derailed/k9s/tree/617476cfc0673be026fba339e2c204e22d505e53
[k9-status]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/config/styles.go#L146-L156
[k9-skin]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/config/styles.go#L785-L803
[k9-cvd]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/skins/modus-vivendi-deuteranopia.yaml#L1-L27
[k9-invert]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/config/color.go#L80-L188
[k9-bypass]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/tchart/sparkline.go#L15
[k9-spark]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/tchart/sparkline.go#L84-L158
[k9-thr]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/config/threshold.go#L77-L104
[k9-title]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/ui/table_helper.go#L23-L33
[k9-sel]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/ui/select_table.go#L119-L128
[k9-delta]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/model1/table_data.go#L426-L461
[k9-header]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/view/app.go#L166-L183
[k9-menu]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/ui/menu.go#L78-L149
[k9-ro]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/ui/action.go#L159-L169
[k9-toggle]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/view/log_indicator.go#L137-L177
[k9-update]: https://github.com/derailed/k9s/blob/617476cfc0673be026fba339e2c204e22d505e53/internal/ui/table.go#L472-L492

[lg-c]: https://github.com/jesseduffield/lazygit/tree/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451
[lg-mix]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/config/theme_config.go#L31-L71
[lg-bgquery]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gocui/color_scheme.go#L56-L81
[lg-author]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/presentation/authors/authors.go#L107-L142
[lg-downsample]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gocui/gui.go#L61-L66
[lg-status]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/presentation/commits.go#L537-L573
[lg-graph]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/presentation/graph/cell.go#L11-L22
[lg-len]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/context/commit_message_context.go#L178-L196
[lg-frame]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gocui/gui.go#L1498-L1530
[lg-squash]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gocui/gui.go#L1465-L1472
[lg-scroll]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gocui/scrollbar.go#L7-L27
[lg-widths]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/presentation/commits.go#L228-L260
[lg-select]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gocui/view.go#L1062-L1096
[lg-layout]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/controllers/helpers/window_arrangement_helper.go#L414-L525
[lg-options]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/options_map.go#L32-L36
[lg-mode]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/controllers/helpers/mode_helper.go#L50-L171
[lg-flush]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gocui/gui.go#L1641-L1659
[lg-spinner]: https://github.com/jesseduffield/lazygit/blob/54cc6af1d77b5a6cec3dc9ad0b203afdb4ad3451/pkg/gui/controllers/helpers/inline_status_helper.go#L113-L178

[nv-c]: https://github.com/Syllo/nvtop/tree/84559095d8c7bee5ddd64003d6e5569cd34af8b6
[nv-plot]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/plot.c#L50-L53
[nv-cross]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/plot.c#L63-L91
[nv-legend]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/plot.c#L110-L113
[nv-rect]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/plot.c#L126-L137
[nv-slot]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface_setup_win.c#L372-L373
[nv-max]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/include/nvtop/interface_options.h#L72-L77
[nv-zero]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L2137-L2141
[nv-meter]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L666-L675
[nv-twolayer]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L684-L692
[nv-temp]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L731-L738
[nv-hide]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L777-L789
[nv-jitter]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L939-L952
[nv-colors]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L579-L599
[nv-sort]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L1690-L1692
[nv-keys]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L2086-L2088
[nv-draw]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/src/interface.c#L2354-L2375
[nv-test]: https://github.com/Syllo/nvtop/blob/84559095d8c7bee5ddd64003d6e5569cd34af8b6/tests/interfaceTests.cpp#L118-L128
