# TUI 화면 문법 감사

운영자가 2026-11-11 에 화면 25장을 주고 "목록·여백·테두리·숫자·언어·들어가는 키가
화면마다 다르다"고 했다. 이 문서는 그 25장과 소스에서 센 것을 적는다. 설계 결정은
[RFC-tui-one-screen-grammar](../rfc/RFC-tui-one-screen-grammar.md)에 있다.

## 관측 범위

- 화면: 설치된 TUI, 2026-11-11 15:41~15:43 KST, 화면에 찍힌 서버 `v0.70.0 b88dd69`.
  캡처는 2410×1512 px 25장이다. 운영자 대화와 내부 글이 들어 있어 저장소에 넣지 않았다.
  아래 표의 글자는 캡처에서 그대로 옮겼다.
- 소스: main `63e8fa0e0a65` 의 `bin/masc_tui*.ml`.
- 본 화면: 운영, 작업(목표 목록·목표 상세·작업 검토·작업 판정·게시판 글), 키퍼(list·state·
  cause·time·memory·age·runtime·24h 보기와 아래 창 story·schedules·memory),
  기능·플러그인(Features 실행 목록·Lane Run·Plugins·리소스), 워크스페이스, 시스템(설정 상태).
- 못 본 것: 빈 상태, 조회 실패 상태, 좁은 창, 채팅, Usage, Fusion, Code, Runtime, Logs,
  `?` 도움말 화면. 도움말이 길다는 것은 운영자 말이고 줄 수는 소스에서 셌다.

## 1. 화면에서 센 것

### 1.1 제목 줄

| 화면 | 제목 줄 |
|---|---|
| 키퍼 | `MASC Keepers (29)` … 오른쪽 끝 `HTTP [연결됨]` |
| 키퍼 list 보기 | `MASC Keepers · 일과 도움` + 아래에 `운영 관측: ok · …` 한 줄 더 |
| 작업 | `MASC 작업  목표  ▸작업 검토·19  작업 판정  HTTP [연결됨]` |
| 작업 판정 | `▸작업 판정 (8 of 4999)` |
| Features 실행 목록 | `MASC Features · Librarian (50 loaded / 2000 retained · ] older)  HTTP [연결됨]` |
| Lane Run | `MASC Lane Run  librarian-exact-b83c…  HTTP [연결됨]` |
| Plugins | `MASC Plugins` (화면 전체를 상자로 두름, HTTP 표시 없음) |
| 리소스 | `리소스` / `▸ All resources (276)` (MASC·HTTP 없음) |
| 게시판 글 | `게시판 · #music` (MASC·HTTP 없음) |
| 워크스페이스 | `MASC 워크스페이스  [me]  HTTP [연결됨]` |
| 운영 | `운영  [me]  HTTP [연결됨]` |
| 시스템 | `설정 상태  9:런타임  p:다음  ▸설정파일  모델 …  HTTP [연결됨]` |

- 맨 위 탭은 `키퍼`인데 제목은 `MASC Keepers`다. `작업` 탭 안의 제목은 `MASC 작업`이다.
- 연결 표시는 오른쪽 끝(키퍼), 탭 바로 뒤(작업·시스템), 없음(리소스·게시판·Plugins) 세 가지다.
- 시스템은 제목 줄에 키 안내(`9:런타임`, `p:다음`)가 탭 이름과 섞여 있다.
- 키퍼 list 보기만 제목 아래에 한 줄이 더 있어 보기 탭 줄이 다른 보기보다 한 줄 아래에 있다.

### 1.2 위치와 개수

`(29)`, `·19`, `(50 of 8347)`, `(8 of 4999)`, `(276)`, `(32)`, `1-24/32`,
`[lines 70-119/338]`, `[lines 1-50/85]`, `본문 행 1-49/75 · 댓글 행 1-48/62`,
`INPUT · RUN INPUT 1-46/169`, `1-23 / 29 · j/k · PgUp/PgDn`, `[awaiting 19]`,
`(50 loaded / 2000 retained · ] older)`. 형식이 열한 가지다. 자리도 제목 옆, 창 왼쪽 아래,
머리글 옆으로 갈린다.

### 1.3 고른 줄 표시

| 방식 | 화면 |
|---|---|
| 줄 전체 흰 반전 | Features 실행 목록, 작업 검토, 작업 판정, 워크스페이스 저장소 |
| 줄 전체 회색 띠 | 키퍼 보기들, 리소스 |
| 흰 반전 + 앞머리 `›` | 키퍼 list 보기, 목표 목록(두 줄을 한 묶음으로) |
| 앞머리 `▸` 만 | 왼쪽 목표 목록, 게시판 왼쪽 목록 |

`▸` 는 고른 줄, 고른 탭, 접힌 그룹, 다음 후보 모델, 하단 소식 줄 머리 다섯 곳에 쓴다.

### 1.4 창 나누기와 구역 머리글

- 창: 제목이 박힌 상자(운영, 워크스페이스, 목표 목록), 세로 줄 하나(게시판, 목표 상세,
  Lane Run), 구분 없음(키퍼, Features), 화면 전체 상자(Plugins), `┌─ json ─` 코드 상자(Lane Run).
- 구역 머리글: `[ 적용 상태 · Application ]`, `[ Candle 지급 기록 [z:조회] ]`,
  `관련 기록 · 연결 항목별 마지막 상태`, `MEMORY GAP 6`, `Failing 7`, `◂ RATE LIMITED 2`,
  `UPDATED WITHIN 3H 10`, `◷ WITHIN 1H 11`, `recovered · failed in 12h`. 아홉 가지다.

### 1.5 시각

| 표기 | 나온 곳 | 시간대 |
|---|---|---|
| `2026-11-11 15:16:49` | 게시판 글·댓글 | 현지 |
| `2026-11-11T06:37:37Z` | 작업 판정 "최근 판정", 목표 생성·갱신·관측 시각 | UTC |
| `11-11 15:36:13` | Features 실행 목록 STARTED | 현지 |
| `11-11 06:41:55` | 목표 상세 "관련 기록" | UTC, 표시 없음 |
| `15:43:43` | 리소스 last check | 현지 |
| `14:34`, `since 15:04`, `15:41` | 하단 소식 줄, 키퍼 since·due | 현지 |
| `2026-11-03`, `11/21 완료` | 목표 기한, 연결 작업 | 날짜만 |
| `daily 14:55:00 UTC`, `daily 09:25:00 +09:00` | 키퍼 schedules | 줄마다 다름 |

같은 15:41 KST 를 한 화면은 `15:41`, 다른 화면은 `06:41:55` 로 적는다. 뒤쪽에는 UTC 라는
표시가 없다. 운영자가 두 화면의 시각을 견주면 아홉 시간 어긋난다.

### 1.6 기간

`243ms`, `1.8s`, `29.2s`, `61s`, `3m15s`, `6m53s ago`, `23m05s 전 종료`, `21m`, `64m`,
`66m`, `67m`, `1h57m`, `2h06m`, `3h35m`, `9h05m`, `24h`, `2d`, `3d`, `2d03h`, `8d`, `11d`,
`in 8h13m`, `built 1h ago`, `failing 37m30s`, `refreshing · 6.1s`.

- 같은 열에 `64m` 과 `1h57m` 이 함께 있다(키퍼 memory·age 보기의 digest·saved 열).
- `61s` 와 `21m` 이 같은 열에 있다(runtime 보기 last).
- `24h` 와 `2d`, `3d` 가 같은 열에 있다.
- 지난 일은 `ago`, `전`, 붙임 없음 세 가지로 적는다.

### 1.7 숫자

`56,274`(쉼표), `8347`·`4999`·`2000`·`2722`·`1379`·`1650`(쉼표 없음), `4.2k`·`1.5k`·`7.9k`·
`3.1k`(줄임), `≥7/48`, `peak ≥21`, `×164`, `1×`, `(+108 more)`, `(+4 more)`, `Σ lag 4.2k`,
`lag 60`. 키퍼 time 보기의 lag 열은 `2722` 이고 memory 보기의 gap 열은 `4.2k` 다.
`+ 64m`, `+ 생성` 의 `+` 는 양수 부호가 아니라 "저장됨" 기호다.

### 1.8 값이 없거나 모를 때

`—`, `?`, `held?`, `미확인`, `일정 미확인`, `일부 미확인`, `미관측`, `미기록`, `미배정`,
`None`, `null`, `no keeper selected`, 빈칸. 열세 가지다. "없다", "아직 안 읽었다",
"읽다 실패했다", "해당 없다"가 글자로 갈리지 않는다.

### 1.9 키 안내 형식

- `키:뜻` 이 기본이다(`j/k:move`).
- 예외: `[c] 완료 요청  [x] 중단`(목표 상세 위), `(i to write)`, `Enter: 상세`(빈칸),
  `Enter 목록  1 최근  2 조회`(쌍점 없음), `s schedules  m memory`(쌍점 없음),
  `Enter→m:기억`, `→:상세`, `Colon:palette`, `…?` 와 `?:도움말` 과 `?:help`.
- 키 묶음: `j/k`, `PgUp/PgDn`(빈칸 없음)과 `Left / Esc`, `a / x:approve / reject`(빈칸 있음).
- 한 줄에 최대 15개가 실린다(목표 상세). 화면 본문 위에 같은 키가 한 번 더 나오는 화면이
  다섯이다(운영, 워크스페이스, 목표 상세, Plugins, 시스템).
- 키퍼 화면만 키 글자에 색이 있다(청록·빨강·흐림). 다른 화면은 모두 회색이다.

### 1.10 들어가기와 나오기

| 화면 | 들어가기 | 나오기 |
|---|---|---|
| 리소스 | `Enter:read` | `Esc:back` |
| Features 실행 목록 | `Right / Enter:prompt` | `Left / Esc:back` |
| 작업 검토 | `Right / Enter:details` | `Esc:back` |
| 작업 판정 | `Right / Enter:verdict` | `Esc:back` |
| 목표 목록 | `Right / Enter:상세` | `Esc:뒤로` |
| 목표 상세 | — | `Left / Esc:뒤로` |
| 워크스페이스 | `Enter:파일` | `Esc:뒤로` |
| 운영 | `Enter:열기` | — (`Left:키퍼`) |
| 키퍼 | `Enter / Right:story / detail` | `Esc:dashboard` |
| 키퍼(아래 창 story 열림) | `Enter / Right:close / detail` | `Esc:close` |
| 키퍼(아래 창 memory 열림) | `Enter / Right:browse / detail` | `Esc:close` |
| 시스템 설정 상태 | — | `v/Esc:설정 원문` |
| Plugins | — | `Esc:back (draft kept)` |

- 키퍼에서는 Enter 와 Right 가 서로 다른 곳으로 간다. 다른 화면에서는 같은 뜻이다.
- 키퍼에서 Enter 는 아래 창 상태에 따라 열기, 닫기, 둘러보기로 바뀐다.
- 운영에서 Left 는 뒤로가 아니라 키퍼 화면으로 간다.
- 하위 보기를 바꾸는 키: `v`(작업·키퍼·운영·워크스페이스·시스템), `Tab`(Features·운영·키퍼
  아래 창), `p`(시스템), `t`(목표/작업), `h`(작업 검토의 queue/history), `b`(게시판 본문/댓글,
  목표의 요약), `z`(게시판 목록·넓게), `1`~`4`(키퍼 memory 창), `9`(시스템).

### 1.11 한 글자 키의 뜻

화면 아래 키 안내에서 읽은 것이다. 실제 동작은 §2 의 dispatcher 조사로 다시 확인했다.

| 키 | 뜻 |
|---|---|
| `v` | view(키퍼) · next Work tab(작업) · 전체 정보(워크스페이스) · 조치 원인(운영) · 설정 원문(시스템) · `v/V` 추천/비추천(게시판) |
| `p` | pause(키퍼) · 승인·질문(운영) · 승인(목표 목록) · 요청(목표 목록 위) · 다음(시스템) |
| `s` | schedules(키퍼) · shutdown(키퍼 age 보기) · save(Plugins) · 정렬(목표) · 음악(운영) |
| `c` | check(리소스) · chat(키퍼) · 댓글(게시판) · 완료 요청(목표) · 대화(키퍼 list) |
| `a` | new(키퍼) · approve(작업 검토) · 등록(워크스페이스) · 근거 확인(목표) |
| `x` | delete(키퍼) · reject(작업 검토) · overrule(작업 판정) · 중단(목표) |
| `z` | 목록·넓게(게시판) · Candle(목표) |
| `d` | Git(워크스페이스) · JEV evidence(Lane Run) |
| `g` | yolo(키퍼) · 퀴즈(운영) |
| `u` | next unchecked(리소스) · runtime(키퍼) · use current revision(Plugins) |
| `l` | logs(키퍼) · pane(리소스·게시판) · read current / reload(Plugins) |

키퍼 화면 하나에서 `s` 가 memory 보기에서는 schedules, age 보기에서는 shutdown 으로 적혀 있다.
`x` 는 키퍼를 지우고, 작업을 반려하고, 판정을 뒤집고, 목표를 중단한다. `p` 는 키퍼에서는
멈춤이고 운영에서는 승인 화면을 연다.

### 1.12 언어

- 열 머리: `TYPE NAME CHECK DETAIL`, `STARTED ACTOR STATUS ELAPSED SLOT`, `keeper … librarian …
  digest gap`(영어) / `작업 … 판정`, `작업 … 자동 검증`, `시각 변화 이전 이후 / 사유`(한국어).
- 상태 낱말: `checked`·`unchecked`, `succeeded`·`cancelled`, `active`, `approve`·`reject`,
  `processing`·`queue full`·`yielded`, `model wait`·`tool wait`·`external`·`streaming`(영어) /
  `진행 중`, `이전 검증 중`·`이전 확인 필요`, `연결됨`, `모델 대기`·`도구 대기`·`외부 대기`·
  `응답 중`(한국어).
- 같은 상태가 두 말로 나온다: 키퍼 time 보기 `model wait` 와 list 보기 `모델 대기`,
  `external` 과 `외부 대기`, `streaming` 과 `응답 중`, `paused` 와 `일시정지`.
- 한 줄 안에서 섞인다: `[ 적용 상태 · Application ]`, `[ Keeper 설정 · Settings ]` 아래
  `Validation: valid`, `/:find  n / N:next / previous match  q:종료`, `d:JEV evidence … ?:도움말`,
  `◷ 확인 중 · 3 scheduled · 3 closed (3 cancelled)`, `161회 확인 · 일부 미확인` 옆 `due lag`.
- 키 안내 줄: 리소스·Features·Lane Run·Plugins·작업 검토·작업 판정·키퍼는 영어,
  게시판·목표·운영·워크스페이스·시스템은 한국어다.
- 입력 줄: `› to geek-scout  (i to write)`, `Choose a Keeper before writing · i:choose`,
  `› no keeper selected`.

### 1.13 줄임

- 이름 가운데를 자른다: `kidsn…dd-manager`, `code-…wer-father`, `e-mas…the-leader`,
  `#verifica…3e8fea897627c0) – {`, `task-2529 T… (applies on 9797d7b127)`.
  Features 실행 목록은 화면 200열 가운데 100열쯤을 쓰고 오른쪽 절반이 비어 있는데
  ACTOR 를 16칸으로 자른다(`lane_subject_width`). 리소스 NAME 도 같다(오른쪽 40%가 빈다).
- 왼쪽 목표 목록은 모든 줄이 `진행 중 ·…` 로 시작하고 제목 앞을 잘라 끝만 남긴다
  (`진행 중 ·…막전 기록·수집·태그`). 32줄의 앞 여섯 칸이 같은 글자다.
- 끝을 자른다: `check outco…`, `claude_code_ac22c1f2.claude-opus-5-5…`.

### 1.14 본문 폭과 밀도

- 게시판 본문과 목표 성공 조건은 한 줄이 한글 80자쯤(160칸 안팎)이다. 줄 끝에서 다음 줄
  머리를 찾기 어렵다.
- 게시판 댓글 창과 Lane Run 은 sha256 64자와 `\n` 이 든 JSON 문자열을 그대로 찍는다.
  Lane Run 왼쪽 창은 글자 전체가 초록이다.
- 워크스페이스는 61행 가운데 4행, 운영은 9행을 쓴다. 나머지는 빈다.

### 1.15 색과 기호

- 노랑: 실패 막대, 경고, `scheduled`, `unchecked`, `cancelled`, 그룹 머리글, 키퍼 pulse 그림.
  키퍼 화면의 그림은 정상 턴도 노랑으로 칠해서 화면의 가장 큰 색 면적이 "이상 없음"이다.
- 청록: 고른 탭, 구역 머리글, 키 글자, lag 막대, `응답 중`, 모델 이름.
- 빨강: 검증 거절, 취소된 기록, `사람 몫`, `result in`, `x:delete`.
- 상태 기호: `● ○ ! ✓ × ◌ ◔ ■ ◇ > ‖ ↩ ◷ ? Σ`. 뜻풀이는 runtime 보기 아래 한 줄
  (`× failed in last walk · ▹ next head · ◌ resting head · ? unread head`)뿐이다.
  `!` 는 failing, stale, 사람 몫 세 곳에 쓴다.

### 1.16 줄이 끼어들고 바뀌는 곳

- `waiting inventory: refreshing · 6.1s` 가 키퍼 표 머리 아래에 끼어들면 모든 키퍼 줄이
  한 줄 내려간다(memory 보기 캡처 둘에서 `world · shared` 줄이 한 줄 차이).
- `선택한 관측이 바뀌었습니다 · j/k:다시 선택` 이 운영 본문 위에 끼어든다.
- 아래 둘째 줄이 `▸ 14:34 삼국지 3 DOS …` 와 `일정 정보가 오래됐을 수 있음` 사이를 오간다.
- 아래 첫 줄의 `조치 필요 4` 뒤가 `· 운영에서 확인` 과 `code-reviewer-sister assignment: …` 로
  바뀌면 키 안내가 네 개만 남는다.

## 2. 소스에서 센 것

`rg` 로 센 값이다. 문자열 리터럴 기준이라 주석에 든 것이 일부 섞인다. "직접 읽음"이라고
적은 줄은 그 함수를 열어 확인했고, 나머지는 검색 결과의 개수다. 경로는 모두 `bin/` 아래다.

### 2.1 공용 부품은 있다. 거치지 않아도 그려진다

| 부품 | 공용 | 공용을 안 거치는 곳 |
|---|---|---|
| 화면 틀 | `surface_chrome`(`masc_tui_render_prim.ml:1636`), `finish_surface`(`:1481`, 직접 읽음) | `box_*` 로 직접 그린 뒤 `finish_surface` 만 부르는 화면 약 45곳 |
| 제목 줄 | 배치 함수 8종(`detail_heading`, `badge_row`, `surface_title_row`, `feature_child_heading`, `config_pane_title`, `planning_workspace_title`, `board_title`, Usage 의 줄임 배지) | 손으로 이어 붙이는 곳 약 15곳(`masc_tui_render_keepers.ml:2455` 등) |
| 표 | `Masc_tui_table`(`cell`, `fit`, `header_row`, `row`, 직접 읽음). 열 정의 11벌이 `masc_tui_render_schedule.ml` 에 있음 | `%-Ns` 로 손 정렬 35곳, 키퍼 표는 별도 구현(`allocate_keeper_columns`, `Masc_tui_keeper_grid`) |
| 위치 표시 | `Masc_tui_scroll.window_text`(`a-b/n`, 37곳) | 감싸는 말 16종 이상(`[lines]`, `[rows]`, `[runs]`, `[entries]`, `본문 행`, `[행]` …)과 독립 형식 6종(`1-23 / 29 · j/k`, `(n of m)`, `[awaiting n]` …) |
| 고른 줄 | `box_line_selected`, `Theme.selection`, `Theme.sidebar_selection` | 띠 3종 × 앞머리 3종(`▸`, `›`, `>`). `>` 를 직접 쓰는 곳 약 28곳, `Ansi.reverse` 직접 16곳 |
| 제목 박힌 상자 | `Masc_tui_card.top_edge`, `studio_panel` | 같은 모양을 따로 그린 곳 4곳, 제목 박힌 가로선 3곳 |
| 구역 머리글 | 없음 | `[ 제목 ]` 을 만드는 곳 6곳. `Failing 7` 과 `MEMORY GAP 6` 은 같은 함수(`keeper_group_heading_text`)에서 나오는데 대소문자 규칙이 다름 |
| 아래 세 줄 | `footer_line`, `agenda_line`, `composer_row` | 둘째 줄은 일정이 없으면 사라짐(`Agenda.rows_taken`). 채팅·글쓰기 화면에는 없음 |
| 본문 알림 | 없음 | 키퍼 표 머리 아래에 최대 6줄을 `box_line` 으로 끼움(`masc_tui_render_keepers.ml:2704`~`2746`, 직접 읽음), 운영 화면 한 줄, `data_unreliable_row` 15곳 |
| 색 | `Masc_tui_ansi.Theme` 의 상태·역할 토큰 | 토큰을 안 거치는 색은 20곳 안쪽. `Ansi.dim` 551번, `Ansi.bold` 223번은 화면이 직접 씀 |

RFC-0459 가 정한 토큰 이름(`text.subtle`, `border.focused`, `surface.raised`)은 코드에 없다.

### 2.2 시각

- 공용: `Terminal_text.short_timestamp`(`YYYY-MM-DD HH:MM:SS`) 등 네 함수, 현지 시간대,
  호출 31곳.
- 공용을 안 거침: `Unix.localtime` 직접 58곳, `Unix.gmtime` 14곳. `clock_text` 라는 같은
  이름의 함수가 네 개이고 형식이 다 다르다.
- 목표 상세 "관련 기록"의 `11-11 06:41:55` 는 `masc_tui_planning_detail.ml` 의
  `event_stamp` 가 서버 ISO 문자열을 글자 위치로 잘라 만든다(직접 읽음). 시간대를 바꾸지
  않아 UTC 다. 작업 이력의 `short_ts` 도 같은 방식이다.
- Features 실행 목록의 `11-11 15:36:13` 은 `lane_run_clock` 이 `Unix.localtime` 으로
  만든다(직접 읽음). 두 화면이 아홉 시간 다르다.
- 서버 ISO 문자열을 그대로 찍는 곳이 20곳 이상이다.
- 일정의 `daily 14:55:00 UTC` 는 서버(`lib/schedule/schedule_domain.ml` 의
  `recurrence_summary`)가 일정마다 저장된 시간대로 만든 글이고 TUI 는 그대로 찍는다.

### 2.3 기간

- 공용: `span_text`(`masc_tui_message_layout.ml`, 직접 읽음). 60초 미만 `Ns`, 1시간 미만
  `MmSSs`, 하루 미만 `HhMMm`, 100일 미만 `DdHHh`. 참조 46곳. `elapsed_text` 는 1초 미만
  `243ms`, 1분 미만 `29.2s` 를 더한다.
- `64m`, `61s` 는 `masc_tui_keeper_grid.ml` 의 `short_span` 이 만든다(직접 읽음). 90초
  미만은 초, 100분 미만은 분, 10시간 미만은 `XhYYm`, 48시간 미만은 `Nh`, 그 위는 `Nd`.
- 그 밖의 사다리가 여덟 개 더 있다. `keeper_lane_idle_text` 는 두 파일에 똑같이 있다.
- 지난 일 붙임: ` ago` 가 든 리터럴 26개, `전` 10곳(다섯 곳은 언어를 안 보고 한국어만).

### 2.4 숫자

- 줄임: `compact_count`(`56.3k`)와 `format_compact_num`(`56k`)이 규칙이 다르다.
- 천 단위 쉼표를 넣는 공용 함수가 없다. 같은 코드가 세 파일에 있다
  (`grouped_int`, `grouped_digits` 둘).
- `string_of_int` 로 바로 찍는 곳 122곳, `%d/%d` 84곳, `+%d more` 22곳(공용 `more_text` 는
  5곳만 씀), `×%d` 10곳.

### 2.5 값이 없을 때

`Glyph.no_value`(`—`) 참조 111곳. 그 밖에 `-` 26곳, `?` 90곳, `미확인` 이 든 줄 101,
`미관측` 54, `미기록` 11, `미배정` 5, `unknown` 41, `none` 23, `unreported` 11.

### 2.6 언어와 상태 낱말

- 언어 타입은 `Lang_ko | Lang_en`, 기본 `Lang_ko`. 공용 선택 함수 `ui_text state ~ko ~en`
  참조 505곳.
- 화면마다 `let text korean english = …` 를 다시 정의한 곳 68개, `if ko then` 376줄.
- 언어 인자 없이 영어만 찍는 표 머리 리터럴 61개(언어 분기가 있는 머리 23개).
  `masc_tui_keeper_strip.ml` 의 `failing`·`recovered`·`paused`, `masc_tui_render_resources.ml`
  의 `TYPE/NAME/CHECK/DETAIL`, `masc_tui_artifact_checks.ml` 의 `checked`·`unchecked`.
- Lane 실행 상태 `succeeded`·`cancelled` 는 `lib/tui_decode.ml` 의 `lane_run_status_label`
  이 variant 를 wire 철자로 되돌린 글자다. 같은 Lanes 화면의 다른 줄은 `성공`·`취소` 로 적는다.
- `keeper_activity_word ?(ko=false)`: 인자를 안 넘기면 영어다. 목록은 넘기고 `● now` 열과
  story 머리는 안 넘긴다. 그래서 같은 상태가 `모델 대기` 와 `model wait` 로 갈린다.
  일정 화면은 같은 variant 에 `tool/model/external/verify` 라는 세 번째 낱말을 붙인다.
- 서버 `lib/server_keeper_waiting_inventory.ml` 이 한국어 문장 48개를 wire 로 보낸다.
  TUI 언어 설정이 닿지 않는다.

### 2.7 기호

`Glyph`, `masc_tui_keeper_mark.ml`, `masc_tui_memory_mark.ml` 세 모듈이 있고 나머지는
리터럴이다(`●` 52, `▸` 75, `×` 37, `○` 36).

| 기호 | 뜻 |
|---|---|
| `×` | 취소된 작업, offline, 취소된 호출, stale, 곱하기 |
| `○` | Todo, paused, idle, unchecked |
| `◌` | Deferred, External_waiting |
| `◇` | Confirmation, Verifying |
| `!` | failing, held call, read error, 우선순위 |
| `▸` | 고른 줄, 고른 탭, 접힌 그룹, 경로 구분, 일정 줄 머리 |

### 2.8 줄임과 구분

- 끝 줄임 `fit_width` 289곳, 가운데 줄임 `truncate_middle`·`fit_middle` 80곳.
  `Masc_tui_table.cell` 의 기본값이 `Fold_middle` 이다(직접 읽음). 그래서 이름 열이
  가운데서 잘린다.
- 폭은 `display_width` 로 센다(476곳). 한글은 두 칸으로 센다.
- ` · ` 리터럴 319개, 구분자 상수 다섯 벌, 이어 붙이는 함수는 `join_fitting` 하나(9곳).

### 2.9 키

`K` 는 `masc_tui_keys.ml`, `M` 은 `masc_tui.ml` 이다.

- 키 표: binding 은 `{key; label; label_ko; help; group; detail; rows}` 이고 화면별 목록은
  `K` 의 `for_surface` 한 match 에 있다. `hints_of_bindings` 가 group 순서로 정렬해 `키:뜻` 을
  잇고, `Masc_tui_footer` 가 폭에 맞춰 뒤에서부터 버린 뒤 `…?` 를 붙인다.
- 표와 dispatcher 가 따로다. `M` 의 키 갈래 가운데 `| Some "…"` 꼴 문자열 리터럴이 350개이고
  (`rg -c '^\s*\| Some \(?\(?"' bin/masc_tui.ml`, 하위 처리기의 `| "…"` 꼴은 따로 더 있다)
  표의 값을 읽는 곳은 10여 곳이다. 키퍼 화면의 안내는 표가 아니라
  `masc_tui_render_prim.ml` 이 손으로 조립한다(직접 읽음).
- 한글 입력 상태에서는 Shift 가 전달되지 않는다(`masc_tui_key_ime.mli`). 쌍자음과 ㅒ·ㅖ 자리인
  `R E Q T W O P` 만 대문자로 읽히고 나머지 대문자 키는 소문자로 읽힌다.
- 한 화면 안의 키 중복을 막는 장치는 컴파일 시점에도 시험에도 없다. 키퍼 목록에 `s` 가 두 번,
  설정 화면에 `x` 가 다섯 번 있다(pane 으로 갈림).
- 뜻이 셋 넘는 글자: `s p v x c a d e o t u m h l r g b w n y`, 그리고 `Enter`, `Esc`,
  `Tab`, `Right`, `[` `]`, 숫자 `1`~`4`.

화면별 뜻(dispatcher 기준):

| 키 | 뜻 |
|---|---|
| `s` | 키퍼 shutdown(아래 창이 닫혔을 때) · schedules(열렸을 때, `masc_tui_keeper_story.ml`, 직접 읽음) · Sandbox 탭 remote_ssh · 서버가 꺼졌으면 서버 시작 · 운영 음악 · 게시판·목표·기억 정렬 · 설정 → 리소스 · 저장 넷 |
| `p` | 키퍼 pause/resume/boot · 운영 승인·질문 · 목표 목록 → 승인 · 목표 Pause · 보기 넘기기 여섯 화면 |
| `v` | 보기 넘기기 열한 화면 · 게시판 추천 · 승인 마지막 답변 · 코드로 보기 |
| `x` | 키퍼 delete · 작업 반려 · 판정 뒤집기 · 작업 취소 · 목표 중단 · 일정 취소 · 설정 값 되돌리기 다섯 · Usage 한도 묶음 표시 |
| `c` | 키퍼 대화 · 게시판 답글 · 목표 완료 요청 · 리소스 확인 표시 · 복사 둘 · 카테고리 둘 · 새 Skill |
| `g` | 키퍼 yolo · 운영 퀴즈 · 활동 맨 위 · 승인 설치 결과 |
| `Enter` | 상세 열기 · 키퍼 아래 창 열기 · 아래 창 story 쪽에서는 닫기 · memory 쪽에서는 둘러보기 |
| `Esc` | 운영으로(게시판·목표·키퍼·저장소·설정 등 열 곳) · 작업으로(일정·검토·판정·승인) · 기능으로(리소스·Clients·Tools) · 채팅에서는 도는 턴 멈춤(직접 읽음) |
| `Tab` | 맨 위 여섯 화면 돌기(직접 읽음) · 아래 창 다음 쪽 · 채팅 완성 |

확인 단계:

| 방식 | 동작 |
|---|---|
| 두 번 누름 | 키퍼 shutdown·delete, 목표 동작 여섯, 작업 승인, 일정 취소, Skill 삭제, 끝내기 |
| 이유 입력 | 목표 중단, 작업 취소, 작업 반려, 판정 뒤집기 |
| 한 번에 실행 | 키퍼 pause·wake·yolo, Sandbox 백엔드 변경(`d` `m` `s`), 승인 `y`/`n`, 판정 동의 `y`, 채팅 턴 멈춤 |

위험한 동작과 무해한 동작이 같은 글자인 곳: `s`(shutdown / 음악·정렬), `p`(pause / 보기 넘기기),
`g`(yolo / 퀴즈·맨 위), `x`(delete / 한도 묶음 표시), `d` `m`(Sandbox 백엔드 변경 / 상세·대화),
`n`(승인 거절 / 다음 찾기), `y`(승인 / 복사).

이동:

- 뒤로 가기 이력이 없다. `Ctrl-]` 로 참조를 따라간 한 단계만 되돌아가고, 다른 화면으로 가면
  지워진다.
- 일정·Fusion·기억은 키퍼 화면 소속인데 `Esc` 는 작업이나 운영으로 간다.
- 보기 바꾸는 키: 키퍼 상세 탭 `[` `]`, 키퍼 목록 `v`, 아래 창 `Tab`·`s`·`m`, 설정·Tools·
  Runtime `p`, Usage `p`·`v`·`1`~`3`·`w`, 작업 `v`·`t`·`p`, 검토 `h`, 활동 `e`·`l`,
  기억 `1`~`4`, 게시판 `f`·`s`·`z`·`b`.

도움말:

- `?` 는 키 표에서 자동으로 만든다. 지금 화면 → 전역 → 슬래시 명령 46개 → 나머지 모든 화면 →
  표식 풀이 순이다. 생성물 `docs/guides/TUI-KEYS.md` 의 표 38개가 머리 행을 빼고 619행이다(직접 셈). 화면별:
  운영 9, 작업 22, 게시판 25, 채팅 26, 키퍼 31, 리소스 33, 시스템 42, 기억 42, 키퍼 상세 55.
- 도움말에 없는 동작이 있다: 키퍼 `d`, 목표 `p`·`r`·`b`·`u`, 승인 `Y`.
- 팔레트(`:`)는 고정 목적지 41곳과 실행 중 데이터 항목을 갖는다. 빈 질의에서는 여섯만 보인다.

## 3. 참고한 원칙과 제품

원문을 읽고 옮긴 것이 아니라 요약 자료로 확인한 개념이다. 쪽 번호는 적지 않는다.

- Don Norman, *The Design of Everyday Things*: 할 수 있는 동작이 보여야 하고(발견 가능성,
  signifier), 조작과 결과의 자리가 대응해야 하며(mapping), 한 일의 결과가 바로 보여야 하고
  (feedback), 틀린 동작은 못 하게 막는다(constraint). 같은 키가 상태에 따라 다른 일을 하면
  사람은 상태를 착각하고 실수한다(mode error). 요약:
  [uxmag](https://uxmag.com/articles/understanding-don-normans-principles-of-interaction).
- Jakob Nielsen 의 사용성 원칙 가운데 일관성과 표준, 기억보다 인식:
  [NN/g](https://www.nngroup.com/articles/ten-usability-heuristics/).
- Ben Shneiderman, "The Eyes Have It"(IEEE Visual Languages 1996, DOI 10.1109/VL.1996.545307):
  전체를 먼저, 좁히고 거른 뒤, 고른 것의 상세.
  [초록](https://drum.lib.umd.edu/items/155a868e-fb83-4115-9899-9187ea8c0498).
- Miller columns: 왼쪽에서 고르면 오른쪽에 그 안이 열리는 여러 단 목록. ranger·yazi 와
  macOS 파일 대화상자가 쓴다. [Wikipedia](https://en.wikipedia.org/wiki/Miller_columns).
- lazygit: `j/k`, `h/l`, 숫자 키의 뜻은 모든 창에서 같고, `?` 는 지금 창의 키만 보여 준다.
  키 문서는 코드에서 생성한다.
  [Keybindings](https://sources.debian.org/src/lazygit/0.57.0%2Bds1-1/docs/keybindings/Keybindings_en.md).
- k9s: `:` 로 어디든 가고 `?` 는 지금 화면의 키를 보여 준다.
  [commands](https://k9scli.io/topics/commands/), [hotkeys](https://k9scli.io/topics/hotkeys/).
- Helix 와 which-key: 앞 키를 누르면 이어 누를 수 있는 키가 작은 창에 뜬다. 공식 문서는
  읽지 못했고 소스 사본에서 `pending` 키와 infobox 구조만 확인했다.

이 원칙을 MASC 에 어떻게 적용할지는 RFC 의 설계 판단이다. 사용자 실험 결과가 아니다.
