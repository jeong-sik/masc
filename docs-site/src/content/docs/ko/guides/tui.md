---
title: 터미널 UI (TUI) 가이드
description: masc-tui의 화면 구성, 이동 키, 화면별 조작법을 다룹니다.
---

`masc-tui`는 MASC 작업 공간의 기본 진입점입니다.

## 실행

```bash
# 바이너리 실행 — 서버가 쓰는 base-path 를 넘기세요
# (새 터미널은 작업 공간이 아니라 홈에서 시작합니다)
masc-tui --base-path ~/masc --port 8935

# 소스 체크아웃에서 빌드해 실행
dune build bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/masc --port 8935
```

서버에 연결되지 않은 상태에서 Keepers 화면의 `s` 키는 같은 디렉터리의 `masc` 바이너리를 실행해 서버를 띄웁니다. 서버가 떠 있을 때의 `s`는 선택한 키퍼를 종료합니다.

서버가 없어도 키퍼 명단과 작업 백로그는 `.masc/`를 디스크에서 직접 읽어 보여 줍니다. 승인, 게시판, 작업(Goals/Review/Verdicts), 런타임, 메모리, 로그, 메시지는 서버가 필요하고, 목록 대신 서버가 필요하다는 안내를 보여 줍니다.

---

## 화면 모습

세 화면입니다. 실제 런타임에서 찍었고, Keeper 이름·작업 제목·경로는 같은 폭의
대역으로 바꿔 두었습니다.

![Overview — 함대 상태 한 줄, 주의가 필요한 Keeper, 작업 목록](/01-overview.png)

![Keepers — Keeper 한 명당 한 줄로 상태, 오토부트, 샌드박스, 런타임, 맡은 작업](/02-keepers.png)

![Activity — 모든 Keeper 의 도구 호출과 턴 경계를 최신순으로](/06-activity.png)

## 서피스 링

`Tab` 및 `Shift+Tab`은 7개 서피스 링(`surface_ring`)을 아래 순서대로 순환하며, 상단 스트립에도 같은 순서로 표시됩니다.

| 서피스 | 보여 주는 것 | 하위 진입 |
|---|---|---|
| **Dashboard** | 오퍼레이터 결정 대기 항목(Needs your decision), 최근 대화 이어가기(Continue), Goal 측정치, Task 흐름, 사용량 요약 | `p`: 요청 목록, `;`: Agenda, `m`: Usage |
| **Work** | 목표(Goals)와 작업(Tasks) (`t` 전환), Task Review·Task Verdicts (`v` 순환), 승인 대기열(Approvals) | `t`: Goals/Tasks 전환, `v`: Goals · Task Review · Task Verdicts |
| **Keepers** | 키퍼 명단, 대화, 로그, 도구 호출, 런타임, 샌드박스 상태와 컨테이너 로그, 보유 시크릿 이름 | `f`: 변경 파일, `Enter`: 10개 상세 탭 |
| **Usage** | 프로바이더 쿼터 범위, 키퍼별 비용·토큰, 일별 프로바이더 리포트, 텔레메트리(`p`) | `p`: 텔레메트리 (`1`함대·활동, `2`키퍼 메모리 자원, `3`게이트 큐) |
| **Board** | 게시글, 답글, 추천·비추천, 첨부파일, `alphatex`/`atex` 타브 악보 렌더링 | `Enter`: 글 읽기, `w`: 글 쓰기 |
| **Workspace** | 등록된 저장소, 최근 24시간 클론 활동(`H`), 워킹 트리 변경(`d`) | `Enter`: 코드 브라우저 |
| **System** | 서버가 읽은 `runtime.toml` (`e` 편집), 모델, 타입 파라미터, 프롬프트, 프리셋, 테마, 음성 | `9`: Runtime (`p`: Lanes, `c`: Clients), `A`: Activity (`l`: Logs), `L`: Logs, `s`: Resources, `t`: Tools |

그 밖의 화면(`Memory`, `Fusion`, `Approvals`, `Schedules`, `Lanes`, `Clients`, `Runtime`, `Browser Lane`, `Collab`, `MSX`, `DOS`, `Play links`)은 커맨드 팔레트에서 `:go <Name>`으로 열거나, Collab은 `&`, Browser Lane은 `B` / `Ctrl-^`로 엽니다.

---

## 화면별 조작

### Approvals
`Work` 또는 `:go Approvals`로 엽니다. 대기열의 각 항목은 한 줄로 표시됩니다. 여러 줄 인자는 `Enter`로 전문을 읽고(`j/k` 스크롤, `Esc` 복귀), `y`로 승인, `n`으로 거절합니다. `R`은 차단 행을 다시 심판에 올리고, `w`는 워크스페이스 게이트 모드, `e`는 외부 서비스 게이트 레인(수동 / 자동 심판 / 상시 허용)을 전환합니다.

### Board
`w`로 글을 쓰고(작성 중 `Ctrl-A`로 로컬 파일을 첨부), 읽는 중 `c`로 답글을 답니다. `v`/`V`는 추천·비추천, `Y`는 글 식별자 링크를 복사합니다. `s`는 정렬(인기·트렌딩·최신·갱신·토론 수), `f`/`F` 및 `H`는 하위 보드(Hearth)로 좁힙니다. 글 읽기 창에서 `1`–`9` 숫자 키를 누르면 `ATTACHMENTS` 아래의 해당 번호 첨부파일을 열거나 재생하며(오디오는 로컬 재생, MIDI는 `runtime.toml`에 `[tui] midi_soundfont`가 설정된 경우 `fluidsynth`로 재생), ```` ```alphatex ```` / ```` ```atex ```` 코드 블록은 기타 타브 악보 박스로 렌더링됩니다. 스레드는 수직 레일로 들여쓰기 깊이를 보여 주고, 작성자는 사람(`@`)과 키퍼(`◐`) 배지로 구분합니다.

### Keepers 상세
`Enter`로 들어가면 `[`/`]`로 열 개 탭을 순회합니다: `Info · Items · Sandbox · Settings · Secrets · GitHub · Identity · Channels · Automation · Runs`.

- **Items** 탭(`Info` 다음 탭)은 슬롯별 18종 초상화 장신구와 Candle 보유·착용 상태를 보여 줍니다.
- **Sandbox** 탭에서 `d`/`m`/`s`는 각각 Docker, MicroVM, Remote SSH로 즉시 전환합니다. 설정 파일을 고치지 않고 전환 즉시 반영됩니다.
- 목록에서 `c` 대화, `l` 로그, `t` 도구 호출, `u` 런타임 레인 선택, `g` 영속 승인 모드(`yolo`/`auto`) 전환(워크스페이스 게이트 루트에 영속 저장되어 서버를 재시작해도 유지되며 다시 `auto`로 바꿀 때까지 유지됨), `p`/`w` 일시정지·깨우기, `s` 종료입니다. Keeper 행을 클릭하면 선택되고, 선택된 행을 다시 클릭하면 `Enter`처럼 상세 화면이 열립니다.

### Work (Goals, Task Review, Verdicts)와 Fusion
Work의 `v`는 세 탭을 순회합니다: Goals, Task Review, Task Verdicts. Goals는 목표 수명주기이고 뒤의 둘은 Task 판정의 앞뒤 절반이라, 순서가 아니라 서로 다른 주제입니다. 심의(Fusion)는 `:go Fusion`(또는 Keeper 상세의 `Runs` 탭)으로 열며, 실행 목록에서 `Enter`로 상세를 엽니다. 실행 중인 행의 `STATE`는 현재 단계를 그대로 보여 줍니다: `accepted`, `panel(N)`, `judge(A/F)`, `computed(A/F)`, `recording(A/F)`.

### Memory
`:go Memory`로 엽니다. `Enter`로 팩트 브라우저를 엽니다. `c`/`C`는 카테고리 필터를 앞뒤로 순환하고, `s`는 정렬을 바꿉니다(최신, 마지막 인출, 인출 횟수, 카테고리, 내용). `/`로 텍스트 필터를 걸고 `n`/`N`으로 일치 항목을 오갑니다. `Esc`로 닫으면 건강 표로 돌아갑니다.

### Workspace와 코드 읽기
Code 브라우저에서 `Enter`는 파일을 열고, `d`는 HEAD 기준 diff, `H`는 이 파일을 touch한 커밋 목록, `b`는 blame, `m`는 이 파일에 붙은 메모, `K`/`D`는 커서 위치의 hover 텍스트와 정의를 언어 서버에 요청합니다.

---

## 서버 시작 대기

서버 시작 전후에 `masc-tui`를 실행하면 대기 화면을 띄우고 `/health`가 준비되기를 기다립니다. 준비되면 곧바로 메인 화면으로 들어갑니다.

---

## 전역 키

| 키 | 동작 |
|---|---|
| `Tab` / `Shift+Tab` | 7개 서피스 링 순환 (`Dashboard` → `Work` → `Keepers` → `Usage` → `Board` → `Workspace` → `System`) |
| `?` | 현재 서피스의 전체 키 표 |
| `:` | 커맨드 팔레트 — `go <surface>`, `keeper <name>`, `settings` |
| `&` / `Ctrl-^` (`B`) | Collab 허브 / Browser Lane 리더 열기 |
| `/` | 검색 — 키퍼 명단, 코드 트리, 대화 요청 탭 |
| `r` | 강제 새로고침 |
| `q` 두 번 | 종료 |

모든 화면의 입력행 위에는 다음 예정 깨어남과 사람 응답을 기다리는 키퍼를 한 줄로 표시합니다. 해당 사항이 없으면 그 줄은 나타나지 않습니다.

---

## 입력행, 슬래시 명령, 턴 준비 표시

하단 입력행은 지목한 키퍼에게 메시지를 보냅니다. 턴이 시작되는 동안 채팅 스트림은 턴 준비(turn preparation) 상태(컨텍스트·기억 조립, 런타임 후보 선택, 대기 중인 `NEXT`/`STEER` 순서 및 `Ctrl-K` 삭제·`Ctrl-P` 인플레이스 편집)를 보여 줍니다.

- `/features`: TUI에서 할 수 있는 기능과 각 기능을 여는 정확한 명령·단축키를 한 줄씩 모아 보여 줍니다.
- `/task <title>`: `masc_add_task`로 작업을 만들고 그 ID를 같은 메시지로 키퍼에게 넘깁니다.
- `/listen`: 선택한 키퍼에 대한 연속 음성 녹음 및 전사를 켜거나 끕니다.
- `/queue`: 선택한 키퍼의 서버 대기열 현황을 조회하며, `/queue clear`는 해당 키퍼의 대기 중인 큐 항목을 비웁니다.
- `/help`: 나머지 슬래시 명령 목록 — 키퍼 전환, 스트리밍 중단·조향(steer), 이미지 첨부, `/play` 초대 발급 등.
- 키퍼가 `masc_ask`로 사람에게 물은 질문도 같은 입력행에서 답합니다.
