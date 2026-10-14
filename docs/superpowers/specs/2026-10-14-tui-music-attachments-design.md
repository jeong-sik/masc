# TUI 음악 첨부 고도화: 재생 · MIDI 정보 · alphaTex 박자/마디 표시

- 날짜: 2026-10-14
- 상태: 설계
- 맥락: 2026-10-13 첨부 공유 스펙(`docs/superpowers/specs/2026-10-13-board-score-sharing-design.md`,
  native stack #42781로 구현됨)의 명시적 후속 + 운영자 요청: "재생 및 각종 박자, 마디,
  이것저것 표시 기능을 TUI에 다 넣고 싶다."
- 전제: dashboard는 거의 쓰지 않으므로 **TUI가 먼저**다 (이전 스펙과 같은 판단).

## 의도와 이유

운영자가 보드에 올린 오디오/MIDI를 TUI에서 바로 듣고, MIDI가 어떤 곡인지(트랙·BPM·박자·길이)를
보고, alphaTex 탭 악보에 제목·BPM·박자·마디 번호가 표시되게 한다. 터미널 안에서의 음악
작업 흐름(올리기 → 보기 → 듣기)이 끊기지 않게 하는 것이 목적이다.

## 목표

1. 보드 읽기 창에서 첨부를 번호로 연다: 오디오/MIDI는 재생, 이미지는 기존 미리보기,
   나머지(Score 포함 Guitar Pro 파일)는 로컬 기본 앱으로 연다.
2. MIDI 파일을 읽어 포맷·트랙·PPQ·BPM·박자·길이를 표시한다.
3. alphaTex 탭에 제목·BPM·박자를 항상 표시하고 마디 번호를 단다.

## 비목표

- 바이너리 Guitar Pro 파싱/렌더링. GP 파일은 로컬 앱으로 연다 (별도의 대형 후속).
- 오선보, MIDI→악보 변환, staff 표기.
- dashboard 렌더러·재생 (alphaTab 등은 2026-10-13 스펙의 후속으로 유지).
- 댓글 첨부, keeper_msg/broadcast 첨부, blob federation.
- 서버측 재생. 재생은 TUI 클라이언트가 로컬에서 한다.
- URL 첨부의 원격 오디오 스트리밍 재생 (URL 첨부는 열기만).

## 반목표 (이렇게 되면 실패)

- 라벨·렌더 경로가 매 프레임 fetch·파싱으로 느려진다. MIDI 정보는 "열 때" 한 번만 읽는다.
- 사운드폰트 없는 MIDI 재생이 조용히 실패하거나 엉뚱한 파일을 재생한다.
- 기존 보드 읽기 키·footer 규칙(`.agents/skills/tui-chat-design`)과 충돌하는 표시가 생긴다.
- 모르는 MIDI 이벤트·division을 조용한 기본값으로 눌러 담는다
  (constitution `strict_parse_no_default`). 읽는 범위 밖이면 명시 variant로 실패한다.
- 재생이 TUI 렌더 루프를 블록한다.

## 제약

- constitution: 닫힌 합타입, 경로 하드코딩 금지(base-path 기반), TUI 검사는 화면
  문구·배치가 아니라 본 요청·저장한 상태·결정만 본다.
- OCaml 5.5 + Eio. 공개 모듈은 `.mli` 먼저 (`docs/guides/CONTRIBUTOR-WORKFLOW.md`).
- Stacked PR(gh stack)으로만 작성. 각 층의 최소 검사는 코어 빌드 (constitution
  `build_and_ci`). 로컬 전체 빌드·CI 대기 루프는 하지 않는다.
- 새 환경변수는 만들지 않는다 (constitution `env_var_sprawl`). 설정은 기존 TUI TOML에 둔다.

## 설계

### 1. 첨부 액션 모듈 (신규 `bin/masc_tui_attachment_action.ml` + `.mli`)

입력은 읽기 경로가 이미 decode한 `board_attachment`(kind · source · name)다
(`bin/masc_tui_types.ml`의 `board_attachment`).

- **artifact fetch**: `GET /api/v1/artifact-bytes/<sha256>` (raw bytes 라우트.
  이미지 경로가 쓰는 `/api/v1/artifacts/<sha>` JSON과 달리 오디오 크기에 맞는 원문 바이트다;
  builder-check로 라우트·CanAdmin 인증·본문 한도 근거 확인 완료:
  `lib/server/server_routes_http_routes_artifacts.ml:207`).
  인증 HTTP는 `Masc_tui_http` 재사용. 저장은 OS 임시 디렉터리의 `masc_attachments/`
  하위에 `<sha256-앞8>·<name>` 형태로 (이미지 바이트 캐시 선례 `bin/masc_tui.ml:3532`
  와 같은 패턴; 이름 충돌은 digest 접두로 해소).
- **URL 첨부**: fetch 없이 바로 "열기"로만 동작한다.
- **동작 (kind별, 닫힌 합타입으로 분기)**:
  - `Ak_audio`: 로컬 플레이어 체인 `[afplay; ffplay -nodisp -autoexit -loglevel error;
    mpg123 -q; play -q]`, 앞에서부터 시도해 첫 성공을 쓴다
    (선례: `lib/voice_bridge_core/voice_bridge_core.ml`의 `local_playback_argvs`.
    다만 voice 의미론·Voice_config 게이트에 묶이지 않도록 TUI 쪽에 동일 로직을 새로 둔다).
  - `Ak_midi`: `fluidsynth`를 찾고, `[tui] midi_soundfont` 설정 경로의 사운드폰트로
    `fluidsynth -i <sf2> <file>`을 실행한다. 설정이 없거나 파일이 없으면
    `open`(macOS)/`xdg-open` 위임 + "사운드폰트 설정이 필요하다"는 안내 상태 줄.
    fluidsynth 자체가 없으면 위임만.
  - `Ak_image`: 기존 이미지 미리보기 경로(`bin/masc_tui_image_requests.ml`)로 연결.
  - 그 외(`Ak_score` 포함 `.gp*` 파일, `Ak_file`, 미지원 kind):
    저장 후 로컬 기본 앱으로 연다. macOS에서 `.gp5`는 설치된 Guitar Pro가 연다.
    열기는 기존 `Masc_tui_browser.open_url` 헬퍼(`open`/`xdg-open` 처리)를 쓴다.
  - `Ak_youtube`/`Ak_external_link`/`Ak_url` 계열: URL을 연다.
- **실행**: 렌더 루프 블록 금지. systhread 백그라운드 실행
  (선례: `Eio_guard.run_in_systhread`). 상태는 `state`의 트랜지언트 한 줄 메시지
  (정확한 표면·필드명은 계획 단계에서 기존 transient 패턴과 맞춘다).
- **동시 재생**: 한 번에 하나. 새 재생 시작 시 이전 프로세스 핸들을 먼저 끝낸다.
  핸들은 모듈 내 ref로 두고, 종료는 기다리지 않는다.
- **결과 타입**: `` `Played | `Opened | `Saved of path | `Failed of reason `` 계열의
  닫힌 합타입. 실패 사유는 화면 한 줄 + 로그.

### 2. MIDI 정보 리더 (신규 `bin/masc_tui_midi.ml` + `.mli`, fetch와 무관한 순수 파서)

- `read : string -> (info, failure) result`. 바이트 문자열 전체를 받는다.
- **읽는 범위**:
  - Header `MThd`: format(0/1/2), 트랙 수, division. SMPTE division(상위 비트)은
    `Unsupported_division`으로 실패 — PPQ만 지원.
  - Track `MTrk`: 델타타임 가변 길이 · running status · meta 이벤트
    (`0x03` 트랙명, `0x51` tempo, `0x58` 박자, `0x59` 조성, `0x2F` EOT)와
    channel 이벤트(상태 바이트 소모만 정확히, Program Change 번호만 집계).
  - SysEx는 길이만큼 걸러 읽는다 (내용은 해석하지 않음 — 이건 "읽지 않음"이 아니라
    스킵이 맞다: 정보 표시에 필요 없음).
- **시간 계산**: 전체 트랙의 tempo 이벤트를 tick 순으로 병합해 tempo map을 만들고,
  각 트랙의 최종 tick을 초로 환산한 뒤 duration = max. tempo 이벤트가 하나도 없으면
  BPM은 `None`(기본값 120를 만들어 내지 않는다).
- **info**: `{ format; track_count; track_names; division_ppq; initial_bpm;
  tempo_changes; time_signatures; duration_sec }`.
- **failure** (닫힌 합타입 + `failure_text`): `Not_midi | Truncated | Bad_varlen |
  Unsupported_division | Unsupported_format of int | Running_status_without_status |
  Meta_truncated` 등 정확한 셋은 구현에서 문서화.
- **표시**: MIDI 첨부를 열 때 fetch → parse → 상단 요약 한 줄
  (예: `MIDI · 3트랙 · 96 BPM · 4/4 · 2:31`) + 재생. 라벨 라인(`Masc_tui_board_attachments.label`)은
  여전히 경량(name · 크기)을 유지한다.

### 3. 보드 읽기 키 바인딩

- `ATTACHMENTS` 블록(`bin/masc_tui_render_board.ml`의 `attachment_lines`) 각 줄 앞에
  `[N]` 번호를 붙인다(1-based). 번호 포맷은 renderer 측에서, label 함수는 그대로 둔다.
- 보드 읽기 모드(`Board_read`)에서 **본문 포커스**일 때 숫자 키 `1`..`9` = N번째 첨부
  액션. 댓글 포커스(right pane)에서는 기존 동작을 유지한다.
  디스패치 지점: `bin/masc_tui.ml`의 `Board_read` 분기(키 핸들링 부근).
- footer 힌트: `Masc_tui_keys.footer_hints_board_read`에 "첨부 있음" 인자를 추가해
  첨부가 있을 때만 `1-9:open` 계열 힌트를 붙인다.
- MIDI를 연 경우 파싱 정보 요약이 상태 줄에 함께 뜬다.

### 4. alphaTex 표시 고도화

- `bin/masc_tui_alphatex_score.ml`: `\title` `\tempo` `\ts`는 지금 "읽고 검사만 하고
  버린다"(`.mli` 원문: "carry nothing into the score"). `t`에
  `title : string option; tempo : int option; time_signature : (int * int) option`
  를 추가해 값을 보존한다. 반복·실패 규칙은 그대로.
- `bin/masc_tui_alphatex.ml`:
  - 박스 안 첫 줄에 헤더를 그린다: 제목(있으면) + `♩=<tempo>` + `<nn>/<dd>`,
    있는 것만 ` · `로 연결. 셋 다 없으면 헤더 줄 자체를 그리지 않는다.
  - 각 시스템 위에 마디 번호 행을 둔다. 번호는 물리 마디 번호(1-based, 반복 전개
    아님)를 마디 시작 열에 정렬. 마디 하나짜리 예에도 붙는다.
  - 기존 실패 상자·fallback·`Too_wide` 규칙은 그대로.
- 가이드 `docs/guides/alphatex-tab.md` 갱신 + 실측 화면 증거.

### 5. 설정

- `[tui] midi_soundfont : string` — TUI 설정 TOML에 추가. 사운드폰트 경로.
  없거나 파일이 없으면 MIDI는 `open` 위임 + 안내 상태 줄.

## 스택 구성 (gh stack, 맨 아래층만 main base)

1. `tui-music/01-alphaTex-display` — score 타입 확장 + 렌더러 헤더/마디 번호 +
   `test_tui_alphatex` 확장 + 가이드.
2. `tui-music/02-midi-info` — MIDI 순수 파서 + `test_tui_midi`(fixture .mid를
   테스트 내에서 바이트열로 생성).
3. `tui-music/03-attachment-action` — fetch/save + 플레이어 체인 + open + 상태 표시.
4. `tui-music/04-board-keys` — ATTACHMENTS 번호 + 1-9 키 + footer 힌트 + MIDI 정보 연결.

1↔2는 독립. 3→4 순서 고정.

## 검증

- 각 층: 코어 빌드 성공 (constitution `build_and_ci`의 최소 검사).
- 테스트는 기존 스타일(`test/test_tui_alphatex.ml`, `test/test_tui_board_attachments.ml`)
  을 따른다. 화면 문구·PTY 시나리오 테스트는 만들지 않는다 — 값·상태·요청만 본다.
- 증거(constitution `evidence`): 실제 TUI 세션에서 오디오 재생·MIDI 정보·alphaTex
  헤더/마디 번호 실측. MIDI 파서는 생성한 fixture로. 보드에 실제 첨부를 올려 번호 키로
  여는 흐름을 실측한다.

## 결정 (운영자 확인 없이 작성자가 정한 것 — 이대로 진행)

- GP 바이너리는 파싱하지 않고 로컬 앱으로 연다. 터미널 내 악보는 alphaTex가 담당.
- URL 첨부는 열기만 (원격 오디오 스트리밍 재생은 비목표).
- 재생은 한 번에 하나. 새 재생이 시작되면 이전 것은 끊는다.
- 마디 번호는 물리 마디 번호다 (도돌이표 전개 번호 아님).
- MIDI 정보 표시는 "열 때" 한 번. 라벨 라인은 경량 유지.
- 첨부 선택은 숫자 키 직접 바인딩 (선택 모드를 새로 만들지 않는다).
- 사운드폰트 경로는 설정으로만 둔다. brew 설치를 코드가 가정하지 않는다.

## builder-check (2026-10-14)

plan 서브에이전트가 설계의 사실 주장을 코드로 검증했다. 결과 **"Nothing important
left"** — 계획을 막는 미해결 질문 없음. 확인된 것: artifact-bytes 라우트·인증·한도,
`board_attachment` 필드(`As_artifact`는 sha256+크기), Board_read에서 숫자키 1-9
미사용·본문 포커스 정의, alphaTex 파서의 지시자 폐기 원문, `[tui]` TOML 추가 경로,
`Eio_guard.run_in_systhread` 패턴. 사소 결정은 계획에 넘긴다.

## 후속

- GP3/4/5 헤더 메타데이터 읽기 (제목·작곡가 등 고정 오프셋 문자열 — 독립 후속으로
  충분히 작다).
- dashboard alphaTab 렌더러 (2026-10-13 스펙 후속).
- MCP 업로드 도구 (이슈 #42782).
