# TUI 음악 첨부 고도화 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 보드 첨부(audio/score/midi)를 TUI에서 번호 키로 열고(재생/열기), MIDI 메타데이터를 표시하고, alphaTex 탭에 BPM·박자·마디 번호를 표시한다.

**Architecture:** 순수 파서/결정 계층(`masc_tui_alphatex_score`, 신규 `masc_tui_midi`, 신규 `masc_tui_attachment_action`)을 먼저 두고, 마지막 층에서 TUI 상태·키·렌더링에 연결한다. 재생은 TUI 클라이언트 로컬 프로세스(afplay 계열, fluidsynth)를 백그라운드로 띄운다.

**Tech Stack:** OCaml 5.5 + Eio, Alcotest.

**Spec:** `docs/superpowers/specs/2026-10-14-tui-music-attachments-design.md`

## Global Constraints

- constitution `execution_protocol`: Stacked PR(gh stack)로만 작성. 맨 아래층만 main base.
  로컬 **전체** 빌드와 CI watch 금지. 각 층의 검사는 가벼운 대상 검사만: 테스트 실행 파일
  (`dune exec test/<name>.exe`)과 TUI 실행 파일(`dune build bin/masc_tui.exe`).
- constitution: 닫힌 합타입(문자열 결과 금지), 경로 하드코딩 금지(`Filename.get_temp_dir_name ()`
  등 기반 함수 사용), strict_parse_no_default(모르는 입력은 명시 variant로 실패).
- TUI 화면 문구·배치·PTY 테스트 금지. 검사는 순수 함수의 값·결정만 본다.
- OCaml 코드 작성 전 `.agents/skills/ocaml-coding/SKILL.md` 읽기. TUI 표시 변경은
  `.agents/skills/tui-chat-design/SKILL.md` 규칙 준수.
- 커밋 시 `.githooks` pre-commit 전체 빌드가 걸리면
  `git -c core.hooksPath=/dev/null commit -m "..."` 사용 (가이드 §2 Commit boundary).
- 새 브랜치 패밀리: `tui-music/01-alphaTex-display` → `tui-music/02-midi-info` →
  `tui-music/03-attachment-action` → `tui-music/04-board-keys`(각 층이 전 층을 base).
- bin 모듈 추가 시 `bin/dune` 배선은 `masc_tui_alphatex_score` 라이브러리 스탠자
  (bin/dune:1280-1302 부근)와 `test/stanzas/test_tui_board_attachments.inc` 를 모범으로 한다.
  테스트는 `(include stanzas/test_<name>.inc)` 를 test/dune에 추가.

## Review Focus

1. **SMPTE division을 쓰는 MIDI** — PPQ만 지원. 명시 variant(`Unsupported_division`)로
   실패해야 하고 "재생됐다"고 하면 안 된다. → Task 2 테스트.
2. **템포가 중간에 바뀌는 MIDI** — duration이 초기 BPM이 아니라 tempo map으로 계산돼야
   한다. → Task 2 테스트(손으로 계산한 기댓값).
3. **running status 이벤트 스트림** — 상태 바이트 생략 시열이 끊기지 않고 읽혀야 한다.
   → Task 2 테스트.
4. **사운드폰트 미설정/미존재** — MIDI가 fluidsynth 없이 "재생된" 척하지 말고 위임+안내로
   가야 한다. → Task 3 테스트(`midi_argv` 결정 함수).
5. **플레이어 체인 전부 실패** — afplay/ffplay/mpg123/play가 모두 없는 환경에서
   `Failed`로 떨어져야 한다. → Task 3 테스트(`player_argvs` + `run` 분기).
6. **깨진 첨부 엔트리(Error)** — 번호 매기기에 포함되고, 열 때 깨진 이유가 상태 줄에
   표시된다. → Task 4 테스트(`attachment_at_index`).

---

### Task 1: alphaTex 헤더(BPM·박자) + 마디 번호

**Files:**
- Modify: `bin/masc_tui_alphatex_score.mli` (`t` 타입, mli 문구)
- Modify: `bin/masc_tui_alphatex_score.ml` (지시자 값 보존)
- Modify: `bin/masc_tui_alphatex.mli` (서명 불변 문서화)
- Modify: `bin/masc_tui_alphatex.ml` (헤더 줄 + 마디 번호 행)
- Test: `test/test_tui_alphatex.ml`
- Docs: `docs/guides/alphatex-tab.md`

**Interfaces:**
- Consumes: 기존 파서 난무 — `\title` `\tempo` `\ts`는 이미 `directive_of_word`에서
  인자를 읽고 검증만 하고 버린다(`bin/masc_tui_alphatex_score.mli:8` "carry nothing
  into the score").
- Produces:
  - `Score.t`가 `title : string option`, `tempo : int option`,
    `time_signature : (int * int) option` 필드를 추가로 갖는다.
  - `Masc_tui_alphatex.render_tab : ?rhythm:bool -> max_width:int -> string ->
    (string list, tab_failure) result` — 서명 불변. 반환 줄의 앞부분에 헤더/번호 행이
    생길 뿐이다.
  - 헤더 줄 형식(있는 것만 ` · `로 연결): `♩=96 · 4/4 · "Riff"`(title은 따옴표 포함
    그대로). 셋 다 없으면 헤더 줄 없음.
  - 마디 번호 행: 각 시스템 바로 위. 물리 마디 번호(1-based)를 해당 마디 시작 열에
    두 자리 고 너비 아닌 그냥 숫자 문자열로, 나머지는 공백.

- [ ] **Step 1: 실패 테스트 추가**

`test/test_tui_alphatex.ml`에 추가:
- `test_directives_are_kept`: `Score.read "\\title \"Riff\" \\tempo 92 \\ts 6 8 :4 0.6"`의
  `title/tempo/time_signature`가 각각 `Some "Riff"` / `Some 92` / `Some (6, 8)`인지.
- `test_directives_absent_are_none`: 음악만 있는 소스에서 셋 다 `None`.
- `test_header_line_drawn`: `render_tab ~max_width:80` on
  `"\title \"Riff\" \tempo 92 \ts 4 4 :4 0.6 3.6"` — 반환 줄 중 `♩=92`와 `4/4`와
  `"Riff"`를 포함하는 줄이 정확히 1개.
- `test_header_line_absent_when_no_directives`: `":4 0.6"` 렌더에 `♩=`를 포함하는 줄 없음.
- `test_measure_numbers`: `":4 0.6 3.6 | :4 5.6 7.6 | :4 0.6 3.6 | :4 5.6 7.6"` 를
  `~max_width:80`으로 렌더 → 마디 번호 행이 있고 `1`과 `2`가 각 마디 시작 열 위치에
  있음(첫 번호 행에서 `"1"`의 인덱스 < `"2"`의 인덱스, 그리고 네 마디가 한 시스템에
  들어가는 폭이면 `"3"`, `"4"`도 같은 행).

- [ ] **Step 2: 실패 확인**

Run: `dune exec test/test_tui_alphatex.exe`
Expected: 컴파일 실패(`Score.t`에 필드 없음).

- [ ] **Step 3: 구현**

`bin/masc_tui_alphatex_score.ml(i)`: `t`에 세 필드 추가. 파서에서 `\title`/`\tempo`/
`\ts` 인자를 이미 읽는 지점(값을 버리는 곳)에서 필드에 저장. 기존 실패 규칙(두 번째
tuning, 인자 없음 등) 불변.
`bin/masc_tui_alphatex.ml`: `systems`가 이미 각 마디 너비를 알고 있으므로(`fill`의
`used` 누적), 각 시스템의 마디 시작 열 리스트를 계산해 번호 행을 그린다. 헤더 줄은
drawn 탭 맨 앞. mli 문구(`carry nothing` 원문) 갱신.

- [ ] **Step 4: 통과 확인**

Run: `dune exec test/test_tui_alphatex.exe`
Expected: 전체 PASS(기존 테스트 포함).

- [ ] **Step 5: 가이드 갱신 + 커밋**

`docs/guides/alphatex-tab.md`에 헤더/번호 행 설명 추가. 실측 화면은 Task 4 이후 증거
세션에서 보드에 붙여 캡처 — 이 계획의 증거 단계(아래) 참조.

```bash
git add bin/masc_tui_alphatex_score.mli bin/masc_tui_alphatex_score.ml \
        bin/masc_tui_alphatex.mli bin/masc_tui_alphatex.ml \
        test/test_tui_alphatex.ml docs/guides/alphatex-tab.md
git -c core.hooksPath=/dev/null commit -m "tui(alphatex): keep title/tempo/ts and draw header line and measure numbers"
```

---

### Task 2: MIDI 메타데이터 리더

**Files:**
- Create: `bin/masc_tui_midi.mli`, `bin/masc_tui_midi.ml`
- Test: `test/test_tui_midi.ml`, `test/stanzas/test_tui_midi.inc`, `test/dune`(include 한 줄)
- Modify: `bin/dune`(masc_tui_midi 라이브러리 스탠자)

**Interfaces:**
- Consumes: 없음(순수).
- Produces (module `Masc_tui_midi`):
  ```ocaml
  type info = {
    format : int;                        (* 0 | 1 | 2 *)
    track_count : int;
    track_names : string option list;    (* meta 0x03, 트랙 순서 *)
    division_ppq : int;
    initial_bpm : int option;            (* 첫 tempo 이벤트; 없으면 None *)
    tempo_changes : (int * int) list;    (* (tick, bpm) 오름차순 *)
    time_signatures : (int * int * int) list; (* (tick, nn, dd) *)
    duration_sec : float option;         (* tempo 이벤트 없으면 None *)
  }
  type failure =
    | Not_midi
    | Truncated
    | Bad_varlen
    | Unsupported_division
    | Unsupported_format of int
    | Running_status_without_status
    | Meta_truncated
  val read : string -> (info, failure) result
  val failure_text : failure -> string
  val summary : info -> string
  (* summary 형식(존재하는 것만 · 로 연결):
     "3 tracks · 96 BPM · 4/4 · 2:31"  — duration은 m:ss *)
  ```

- [ ] **Step 1: 실패 테스트 작성**

`test/test_tui_midi.ml`. 테스트 안에서 SMF 바이트열을 헬퍼로 조립
(예: `chunk tag len bytes`, `varlen n`, `meta dt ty bytes`).
- `test_minimal_type0`: 헤더(fmt0, 1트랙, PPQ 480) + 트랙(tempo 500000μs=120BPM,
  4/4, 480틱 음표 하나, EOT). 기대: format 0, division_ppq 480, initial_bpm (Some 120),
  time_signatures [(0,4,4)], duration_sec Some (0.5).
- `test_tempo_change_mid_song_duration_uses_tempo_map`: PPQ 480, 480틱 @120BPM →
  중간에 250000μs(240BPM)로 변경 후 480틱 더. duration = 0.5 + 0.25 = 0.75.
  tempo_changes = [(0,120); (480,240)].
- `test_running_status`: 0x90 상태 후 상태 없이 두 음표(0x90 생략) — 끝까지 읽고
  EOT 도달, 실패 아님.
- `test_no_tempo_events_duration_none`: tempo 메타 없는 트랙 → initial_bpm None,
  duration_sec None. summary에 "BPM" 없음.
- `test_smpte_division_fails`: division 상위 비트 켠 헤더 → Error Unsupported_division.
- `test_format3_fails`: → Error (Unsupported_format 3).
- `test_garbage_fails`: "hello" → Error Not_midi. 빈 문자열 → Truncated.
- `test_track_names`: 두 트랙에 0x03 메타 "a","b" → ["Some a"; "Some b"] 형태.

- [ ] **Step 2: 실패 확인**

Run: `dune exec test/test_tui_midi.exe`
Expected: 컴파일 실패(모듈 없음).

- [ ] **Step 3: 구현**

`bin/masc_tui_midi.ml`: 청크 순회(MThd→MTrk). varlen 디코더(최대 4바이트, 상위 비트
연속 규칙). running status 유지(0xF0/0xF7/0xFF는 상태 리셋 안 함 — SysEx 이후에도
유지하는 SMF 규칙대로). tempo map 병합 후 duration = max(트랙별 누적 초). 실패는 위
variant로만. `.mli`에 읽는 범위 명시.

- [ ] **Step 4: 통과 확인**

Run: `dune exec test/test_tui_midi.exe`
Expected: PASS.

- [ ] **Step 5: 커밋**

```bash
git add bin/masc_tui_midi.mli bin/masc_tui_midi.ml bin/dune \
        test/test_tui_midi.ml test/stanzas/test_tui_midi.inc test/dune
git -c core.hooksPath=/dev/null commit -m "tui(midi): SMF metadata reader (tracks, tempo map, time signatures, duration)"
```

---

### Task 3: 첨부 액션 모듈 (fetch/save/재생/열기)

**Files:**
- Create: `bin/masc_tui_attachment_action.mli`, `bin/masc_tui_attachment_action.ml`
- Test: `test/test_tui_attachment_action.ml`, `test/stanzas/test_tui_attachment_action.inc`, `test/dune`
- Modify: `bin/dune`(라이브러리 스탠자 + masc_tui 실행 파일 libraries)

**Interfaces:**
- Consumes: `Masc_tui_types.board_attachment`/`board_attachment_kind`(As_url/As_artifact),
  `Masc_tui_http.http_get`, `Masc_tui_browser.open_url`, `Masc_tui_midi.read/summary`.
- Produces (module `Masc_tui_attachment_action`):
  ```ocaml
  type action = Play_local | Play_midi | Open_external
  val action_of : Masc_tui_types.board_attachment_kind -> action
  (* Ak_audio→Play_local; Ak_midi→Play_midi; 나머지(이미지 포함)→Open_external *)

  val cache_dir : unit -> string
  (* Filename.get_temp_dir_name () / "masc_attachments", 없으면 생성 *)

  val target_path : name:string option -> sha256:string -> string
  (* cache_dir/<sha 앞8>·<basename|attachment>  *)

  val player_argvs : ?path_value:string -> path:string -> unit -> string list list
  (* [afplay; ffplay -nodisp -autoexit -loglevel error; mpg123 -q; play -q]
     PATH에서 발견된 것만, 순서 유지. 선례: voice_bridge_core.local_playback_argvs *)

  val midi_argv :
    ?path_value:string -> path:string -> soundfont:string option -> unit ->
    (string list, string) result
  (* fluidsynth 발견 + soundfont Some 존재 → Ok [fluidsynth; -i; sf; path]
     fluidsynth 없음 → Error "no fluidsynth ..."
     soundfont None/파일 없음 → Error "no MIDI soundfont ..." *)

  type result_kind = Played | Opened | Saved | Failed of string
  type outcome = {
    name : string;
    result : result_kind;
    midi_summary : string option;  (* MIDI이고 파싱 성공했을 때만 Some *)
  }
  val describe_outcome : outcome -> string
  (* "playing <name>" | "opened <name>" | "saved <name> · <path>"
     | "failed <name> · <reason>"; midi_summary 있으면 뒤에 " · <summary>" *)

  val run :
    host:string -> port:int ->
    Masc_tui_types.board_attachment ->
    midi_soundfont:string option -> outcome
  (* As_url → Open_external(브라우저 오픈, name=url).
     As_artifact → fetch(/api/v1/artifact-bytes/<sha>) 후:
       Play_local → 캐시 저장 + 백그라운드 플레이어(한 번에 하나, 이전 프로세스 종료)
       Play_midi → 저장 + Masc_tui_midi.read로 summary, midi_argv Ok면 백그라운드
                   재생, Error면 브라우저 위임 + Failed 사유에 안내 포함
       Open_external → 저장 + Saved{path} 후 브라우저 오픈 시도, 오픈 성공이면 Opened
     fetch 실패 → Failed{reason}. *)
  ```
  배선 참고: `run` 낸의 fetch는 동기(`Masc_tui_http.http_get`), 플레이어 프로세스만
  백그라운드(`Eio_guard.run_in_systhread` + Unix.create_process, pid를 모듈 ref에
  보관해 다음 재생 전 종료). 프로세스 관리는 `.agents/skills/ocaml-coding/SKILL.md`
  규칙 준수.

- [ ] **Step 1: 실패 테스트 작성**

`test/test_tui_attachment_action.ml`(알꼬 테스트; 임시 디렉터리 조작은 Unix +환경 PATH):
- `test_action_of_maps_all_kinds`: 8개 kind + `Ak_unknown "x"` 각각 기대 action.
- `test_target_path_uses_digest_prefix_and_basename`: name `Some "riff.gp5"` →
  `String.starts_with ~prefix:(cache_dir ())` 경로, basename이 `sha8` 접두 + `riff.gp5`.
  name None → digest만.
- `test_player_argvs_empty_without_path`: `~path_value:(Some "/nonexistent")` → [].
- `test_player_argvs_picks_first_available`: 임시 dir에 `afplay` 실행 파일 만들고
  `~path_value` 지정 → 첫 원소가 그 afplay 경로.
- `test_midi_argv_no_fluidsynth`: path에 없음 → Error.
- `test_midi_argv_no_soundfont`: fluidsynth 가짜 있음 + soundfont None → Error;
  soundfont Some 인데 파일 없음 → Error; Some 존재 파일 → Ok ["fluidsynth"; "-i"; sf; path].
- `test_describe_outcome`: 네 result_kind + midi_summary 유무 조합의 문자열.

- [ ] **Step 2: 실패 확인**

Run: `dune exec test/test_tui_attachment_action.exe`
Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

위 시그니처대로. `run`에서 실제 네트워크/프로세스 경로는 이 테스트로 커버하지 않고
Task 4의 실측으로 증명(evidence 규칙).

- [ ] **Step 4: 통과 확인**

Run: `dune exec test/test_tui_attachment_action.exe`
Expected: PASS. 그리고 `dune build bin/masc_tui.exe` 성공(배선 확인).

- [ ] **Step 5: 커밋**

```bash
git add bin/masc_tui_attachment_action.mli bin/masc_tui_attachment_action.ml bin/dune \
        test/test_tui_attachment_action.ml test/stanzas/test_tui_attachment_action.inc test/dune
git -c core.hooksPath=/dev/null commit -m "tui(board): attachment action module (fetch, cache, local playback, open)"
```

---

### Task 4: 보드 읽기 번호키 연결 + 상태 표시 + MIDI 정보

**Files:**
- Modify: `bin/masc_tui_types.ml`(state 필드 7252 부근 + 초기값 11199 부근)
- Modify: `bin/masc_tui.ml`(open_board_post 13615 부근 초기화; 보드 읽기 키 디스패치 25650~25950; 설정 로드 지점)
- Modify: `bin/masc_tui_board_attachments.ml(i)`(`attachment_at_index` 추가)
- Modify: `bin/masc_tui_render_board.ml`(ATTACHMENTS 번호 + 상태 줄)
- Modify: `bin/masc_tui_keys.ml(i)`(`footer_hints_board_read`에 `~has_attachments`)
- Modify: `bin/masc_tui_config.ml(i)`(`t`에 `midi_soundfont : string option`)
- Test: `test/test_tui_board_attachments.ml`(at_index 계열)
- Docs: `docs/TUI-GUIDE.md` 보드 읽기 항목

**Interfaces:**
- Consumes: Task 3의 `Masc_tui_attachment_action.run/describe_outcome`,
  Task 2의 `Masc_tui_midi`(run 낸에서 사용).
- Produces:
  - `Masc_tui_board_attachments.attachment_at_index : board_attachment_entry list -> int -> board_attachment_entry option`
    (1-based; 범위 밖 None).
  - state 필드 `mutable board_attachment_status : string option`(본문 읽기 창의
    하단 recede 스타일 한 줄; `open_board_post` 시 None).
  - `Masc_tui_keys.footer_hints_board_read ~has_attachments:bool`(true면
    `o:all comments` 앞에 `1-9:attachment` 힌트 삽입).
  - `Masc_tui_config.t` 필드 `midi_soundfont : string option`(`runtime.toml` 없으면 None).

- [ ] **Step 1: 실패 테스트 추가**

`test/test_tui_board_attachments.ml`:
- `test_attachment_at_index_picks_nth`: 3엔트리(Ok, Error, Ok) 리스트에서 1→Ok 첫째,
  2→Error 둘째, 3→Ok 셋째, 0/4→None.
- `test_attachment_at_index_empty` → None.

- [ ] **Step 2: 실패 확인**

Run: `dune exec test/test_tui_board_attachments.exe`
Expected: 컴파일 실패(`attachment_at_index` 없음).

- [ ] **Step 3: 구현**

- `masc_tui_board_attachments.ml(i)`: `attachment_at_index`.
- `masc_tui_types.ml`: state 필드 추가 + 초기값.
- `masc_tui_config.ml(i)`: `midi_soundfont_of_doc` + `t` 필드; 키 이름
  `"midi_soundfont"`(tui_table 접두 규칙 동일).
- `masc_tui_render_board.ml`:
  - `attachment_lines`에서 `List.mapi`로 `"  [%d] %s"`(i+1) 포맷.
  - 상태 줄: `state.board_attachment_status`가 Some면 창 하단
    window-reading 줄 옆/아래 recede 한 줄로 출력. `board_post_error` 스타일 톤
    유지(정보니 recede, 실패 사유 포함 시 그대로 recede — 색 분기 없음).
- `masc_tui_keys.ml(i)`: `~has_attachments` 인자 추가, 호출 지점
  (`masc_tui_render_board.ml:1116`)에서 `list_post.bp_attachments <> []` 전달.
- `masc_tui.ml` 보드 읽기 키 디스패치:
  - 본문 포커스(`board_focus = Right_pane && not board_comments_focused` —
    render 쪽 표현을 그대로 쓰지 말고 실제 포커스 판정과 동일한 조건)에서 `"1"`..
    `"9"` → `int_of_string_opt` → 열린 글의 `bp_attachments`(디테일 우선, 렌더와 같은
    해석)로 `attachment_at_index` → 없으면 무시, `Error reason`이면 상태 줄에
    `깨진 첨부 사유`, `Ok att`이면
    `Masc_tui_attachment_action.run ~host:server_peer_host ~port:state.port att
       ~midi_soundfont:(config의 값)` → `describe_outcome`을 상태 필드에 기록.
    설정값은 기존 config 로드 지점에서 한 번 읽어 전달(없으면 None).

- [ ] **Step 4: 통과 확인**

Run: `dune exec test/test_tui_board_attachments.exe`
Expected: PASS.
Run: `dune build bin/masc_tui.exe`
Expected: 성공.

- [ ] **Step 5: 문서 + 커밋**

`docs/TUI-GUIDE.md` 보드 읽기 항목에 첨부 번호키·재생·MIDI 정보 문단 추가.

```bash
git add bin/masc_tui_types.ml bin/masc_tui.ml bin/masc_tui_board_attachments.mli \
        bin/masc_tui_board_attachments.ml bin/masc_tui_render_board.ml \
        bin/masc_tui_keys.mli bin/masc_tui_keys.ml bin/masc_tui_config.mli \
        bin/masc_tui_config.ml test/test_tui_board_attachments.ml docs/TUI-GUIDE.md
git -c core.hooksPath=/dev/null commit -m "tui(board): numbered attachment keys with playback, midi info, and status line"
```

---

## 증거 (Task 4 이후, constitution evidence)

실행 파일로 로컬 MASC 인스턴스를 띄워 TUI로 실측:
1. 테스트 .mid(테스트 픽스처와 다른 실제 곡 구조, tempo 변경 포함)와 .mp3(짧은
   무전음 wav로 대체 가능)를 보드 글에 첨부.
2. 번호키로 MIDI를 열어 요약 줄(트랙·BPM·박자·길이)과 재생 성공 확인 — 로그 증거.
3. alphaTex 펜스 글(♩/박자/마디번호) 보드에서 열어 화면 확인 — tmux 캡처.
4. 스택 PR 4개를 gh stack으로 열고(맨 아래만 main), 각 층 코어 빌드/테스트 결과를
   PR 본문에 기록. 리뷰 에이전트를 병렬로 붙여 P0/P1/P2 정리.
