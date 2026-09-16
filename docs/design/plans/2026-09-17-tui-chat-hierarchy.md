# TUI 채팅 위계 재설계 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 채팅 화면의 밝기 축을 위계 전용으로 회수하고(말만 full fg, 일·증거·크롬은 한 단계 아래), 끝난 일(스킬·도구) 줄을 기존 Ctrl-D 축 뒤로 접어, 대화가 화면의 주인공이 되게 한다.

**Architecture:** 스펙: `docs/design/2026-09-17-tui-chat-hierarchy-design.md`. 두 개의 stacked PR.
PR 1(브랜치 `tui-chat-hierarchy`)은 스타일만 — `Chat_theme.body`/`origin` 팔과 마크다운 reopen 규칙, 날짜 레일·시계·저널·브레드크럼 recede.
PR 2(브랜치 `tui-chat-work-fold`, base 는 PR 1)는 구조 — 스킬 줄을 `msg_tool_visibility` 토글에 합류시키고, `SKILL`/`TOOLS`/`THINKING` 라벨 단어를 지운다.

**Tech Stack:** OCaml 5.5 (dune), Python PTY 스위트 (`test/test_tui_keyboard_input.py` 계열), gh CLI (PR·CI 디스패치).

## 저장소 작업 규칙 (constitution 에서 온 것 — 실행 에이전트가 반드시 따른다)

- **태스크 안에서 로컬 빌드/테스트 루프를 돌리지 않는다.** 검증은 PR 경계 태스크(Task 7, Task 13)에서 한 번씩만 한다. 경계 태스크의 `dune build bin/masc_tui.exe` + PTY 시나리오 실행은 constitution 의 evidence 조항("실측된 것을 로그로 증명")을 위한 것이다. CI 디스패치 후 기다리며 폴하지 않는다 — 다음 작업을 진행한다.
- 커밋은 태스크마다. PR 은 경계 태스크에서 만든다.
- 한 PR 이 끝나고 다음 PR 로 넘어갈 때 적대적 리뷰 에이전트를 병렬로 붙인다 (경계 태스크에 포함).
- 한국어 문구는 소스에 리터럴로 쓴다. 바이트 이스케이프를 손으로 적지 않는다.
- 렌더 파일만 고친 PR 은 PTY 스위트가 PR CI 에서 선택되지 않는다. needle 이 사는 `test/test_tui_keyboard_input.py` 를 같은 PR 에서 고쳐야 그 스위트가 같이 돈다.

## 조사로 확정한 사실 (이 계획의 근거)

- `Chat_theme.body` (`bin/masc_tui_ansi.ml:486-497`): User/Inbound/Keeper/Tool/Local/Journal 본문이 전부 `Ansi.reset`. Thinking 만 `Ansi.dim`.
- `Chat_theme.origin` (`bin/masc_tui_ansi.ml:464-484`): Tool = `Theme.tool_origin ()`(bright magenta), Journal = `Theme.info ()`(bright cyan), Skill 은 상태색(info/ok/warn/bad).
- **마크다운 지뢰**: `Chat_theme.body_context` (`bin/masc_tui_ansi.ml:534-574`)가 비-ambient 스타일 전부에 `markdown_close = Ansi.reset` 을 쓴다. 본문을 dim 으로 바꾸면 bold/code 스팬이 닫히는 순간 dim 이 지워진다. `inline_restore = Ansi.reset ^ opening` 패턴이 이미 있으니 close 를 같은 모양으로 맞춘다.
- 날짜 레일: `bin/masc_tui_render_chat.ml:426-427` — `~style:(Theme.info () ^ Ansi.bold)`.
- 시계는 gutter 의 `marked` 세그먼트(시계+마크 한 덩어리)에 `Chat_theme.origin ^ Ansi.bold` 로 칠해진다 (`bin/masc_tui_render_chat.ml:375-388`). 시계만 내리려면 메시지 레이아웃이 시계 경계를 낼해야 한다 (`bin/masc_tui_message_layout.ml` 의 row 레코드에 `gutter_clock_cells` 추가 — gutter 조립은 `origin_gutter` 1284-1393, 칸 경계 `gutter_label_at` 1370).
- 스킬 요약 줄: `Keeper_chat_transcript.skill_rows ~full:false` (`bin/masc_tui_keeper_chat_transcript.ml:856-898`)가 정확히 스펙의 체인 줄 모양이다: `**전달됨, 도구 씀** · **ci-red-attribution** · 1 action`. 지금은 커밋분(`bin/masc_tui_render_chat.ml:1200-1202`)과 라이브분(`:2166-2171`)이 `~full:true` 고정이라 proof·↳·detail 이 항상 나온다.
- 도구는 이미 접혀 있다: 기본값 `Tools_compact` (`bin/masc_tui_types.ml:227-229` 타입, `create_state` 의 기본인자 `?(tool_visibility = Tools_compact)`, 토글 :346-349, Ctrl-D 핸들러 `bin/masc_tui.ml:1573-1582`). Compact 투영은 ≤2 호출이면 호출별 줄(`✗ masc_fusion · 1200ms` 모양), 3개 이상이면 inventory 헤더 + 실패/진행 중은 독립 줄(`trouble_activities`, `bin/masc_tui_keeper_chat_transcript.ml:998-1036`). **"실패는 선다"는 이미 있다.**
- 라벨 단어: 커밋분 `base_role_label_of` (`bin/masc_tui_render_chat.ml:1104-1107`), 라이브분 `label "TOOLS"/"SKILL"/"THINKING"` (`:2154,:2161,:2165`). 칸(10칸)은 그대로 두고 단어만 지운다 — `align_role_label` 이 빈 라벨을 마크+패딩으로 그린다.
- L0(진행 중 bright accent)는 이미 있다: `IN PROGRESS` 헤딩 accent+bold (`bin/masc_tui_render_chat.ml:2637-2729`), running 호출 `◌`/`▶` + `Theme.info`. 새로 만들지 않는다 — 다른 것을 누르는 것으로 유일한 accent 가 된다.
- 생각(thinking)은 기본 `Reasoning_hidden` (`bin/masc_tui_types.ml` `create_state` 기본인자) — 손댈 것 없다.

## 스펙과의 차이 둘 (사용자 승인 필요 — 구현 전 확인)

1. **§4.1 의 혼합 체인(`◆ 스킬 · ■ 도구` 한 줄)은 역할별 한 줄로 실현한다.** 스킬 줄과 도구 줄이 각각 한 줄씩(성공 턴 = 최대 2줄). 이유: 마크 칸이 레인 정체성을 답한다는 여백 계약상 한 줄의 마크 칸은 하나의 레인만 말할 수 있고, 두 레인을 한 줄에 섞으면 두 번째 마크가 본문 인라인으로 들어가는 새 패턴이 필요하다. 스펙 §4의 Before→After 예시(2줄)와 정합이다.
2. **3개 이상 호출 블록의 inventory 헤더는 기존 카운트 형식(`이름 ×N`)을 유지한다.** 이름+시간 체인은 폭을 자주 넘겨서 오히려 줄이 늘어난다. ≤2 호출 블록은 기존처럼 호출별 줄이라 스펙의 `■ name · 0.8s` 모양 그대로다.

## 파일 지도

PR 1 (스타일):
- Modify: `bin/masc_tui_ansi.ml` — `Chat_theme.body`/`origin` 팔, `body_context` close 규칙, `link_style_restore`
- Modify: `bin/masc_tui_render_chat.ml` — 날짜 레일(:426-427), 시계 페인트(:375-388), 도구 절 드레싱(:258-304, :418-425), 브레드크럼(:1896-1899)
- Modify: `bin/masc_tui_message_layout.ml` — row 레코드에 `gutter_clock_cells` + gutter 조립
- Test: `test/test_tui_keyboard_input.py` — 날짜 레일 needle (:6994-7006)

PR 2 (구조):
- Modify: `bin/masc_tui_render_chat.ml` — 스킬 ~full 토글 합류(:1188-1202, :2166-2171) + 1191 주석 재작성, 라벨 단어 삭제(:1104-1107, :2154, :2161, :2165)
- Test: `test/test_tui_keyboard_input.py` — chat-clarity(:7770 시나리오 일대), autonomous-turn(:6917 시나리오 일대) needle
- Docs: `.agents/skills/tui-chat-design/SKILL.md` — 라벨·접힘·recede 변경분 동기화

---

## PR 1 — 밝기 재조정 (브랜치 `tui-chat-hierarchy`)

### Task 1: 본문 dim 팔 + 마크다운 reopen 규칙

**Files:**
- Modify: `bin/masc_tui_ansi.ml:464-509` (`Chat_theme.origin`/`body`/`link_foreground`), `:534-574` (`body_context`)

- [ ] **Step 1: `Chat_theme.body` 에 dim 팔을 둔다**

현재 (`bin/masc_tui_ansi.ml:486-497`):

```ocaml
  let body : Masc_tui_message_layout.style -> string = function
    | Masc_tui_message_layout.User | Masc_tui_message_layout.Inbound
    | Masc_tui_message_layout.Keeper -> Ansi.reset
    | Masc_tui_message_layout.Status -> Theme.warn ()
    (* The badge is quiet; the body is not dimmed. A command list is read. *)
    | Masc_tui_message_layout.Local -> Ansi.reset
    | Masc_tui_message_layout.Journal -> Ansi.reset
    | Masc_tui_message_layout.Error -> Theme.bad ()
    | Masc_tui_message_layout.Tool -> Ansi.reset
    | Masc_tui_message_layout.Skill skill ->
      origin (Masc_tui_message_layout.Skill skill)
    | Masc_tui_message_layout.Thinking -> Ansi.dim
```

변경:

```ocaml
  let body : Masc_tui_message_layout.style -> string = function
    (* Speech keeps the terminal foreground: it is the protagonist, and
       everything below it in the hierarchy recedes instead. *)
    | Masc_tui_message_layout.User | Masc_tui_message_layout.Inbound
    | Masc_tui_message_layout.Keeper -> Ansi.reset
    | Masc_tui_message_layout.Status -> Theme.warn ()
    (* The badge is quiet; the body is not dimmed. A command list is read. *)
    | Masc_tui_message_layout.Local -> Ansi.reset
    | Masc_tui_message_layout.Error -> Theme.bad ()
    (* Work, background news and skill chatter sit one rung below speech. *)
    | Masc_tui_message_layout.Journal -> Ansi.dim
    | Masc_tui_message_layout.Tool -> Ansi.dim
    | Masc_tui_message_layout.Skill _ -> Ansi.dim
    | Masc_tui_message_layout.Thinking -> Ansi.dim
```

- [ ] **Step 2: `Chat_theme.origin` 의 Tool·Journal 배지를 내린다**

`bin/masc_tui_ansi.ml:464-484` 에서 두 팔만 변경:

```ocaml
    | Masc_tui_message_layout.Journal -> Theme.recede ()
```

```ocaml
    | Masc_tui_message_layout.Tool -> Theme.quiet_origin ()
```

Skill 팔(info/ok/warn/bad)은 상태색이므로 그대로 둔다. 도구의 상태색은 본문 안의 호출 마크(`◌ ▶ ✓ ✗` — `render_chat.ml` 의 `tool_marker_color`)가 이미 답한다.

- [ ] **Step 3: `body_context` 의 close 가 본문 스타일을 다시 연다**

`bin/masc_tui_ansi.ml:559-574` 의 공용 팔:

```ocaml
      { opening
      ; markdown_close = Ansi.reset
      ; inline_restore = Ansi.reset ^ opening
      ; ...
```

를

```ocaml
      { opening
      ; markdown_close = Ansi.reset ^ opening
      ; inline_restore = Ansi.reset ^ opening
      ; ...
```

로 바꾼다. User 의 두 팔(:538-555)은 그대로(ambient 은 이미 자기 close 를 쓰고, 비-ambient User 는 `opening = Ansi.reset` 이라 같은 바이트다).

- [ ] **Step 4: dim 본문의 bare link 복원**

`bin/masc_tui_ansi.ml:499-509` 의 `link_foreground`: Tool/Journal/Skill/Thinking 이 `Ansi.default_fg` 라 dim 본문의 링크 뒤가 밝게 샌다. 이 네 스타일에 한해 `link_style_restore` 가 `Ansi.no_underline ^ Ansi.dim` 을 반환하게 한다 (`link_style_restore` 정의를 link_foreground 대신 body 를 보게 바꾸는 쪽이 낫다 — 단 Status/Error 는 기존 warn/bad 유지).

- [ ] **Step 5: Commit**

```bash
git add bin/masc_tui_ansi.ml
git commit -m "fix(tui): work and journal bodies recede one rung below speech"
```

### Task 2: 도구 절 드레싱이 dim 을 보존한다

**Files:**
- Modify: `bin/masc_tui_render_chat.ml:258-313` (`dress_tool_clause`/`dress_tool_summary`), `:411-425` (본문 오픈)

- [ ] **Step 1: 기존 코드를 읽는다** — `dress_tool_clause`(:258-304)와 `dress_tool_summary`(:308-313) 전체. 각 절이 색을 입히고 `Ansi.reset` 으로 닫는 구조를 확인한다.

- [ ] **Step 2: 절 close 를 dim 재오픈으로 바꾼다**

`dress_tool_clause` 안에서 절을 닫는 모든 `Ansi.reset` 을 `Ansi.reset ^ Ansi.dim` 으로 바꾼다 (본문이 이제 dim 이므로). 함수가 reset 문자열을 상수로 들고 있으면 인자 하나로 바꾼다.

- [ ] **Step 3: 도구 본문 오픈을 context 로 통일**

`:423-425`:

```ocaml
        box_line_styled buf cols
          ~style:(if is_tool then Ansi.reset else context.opening)
          (dress text)
```

→

```ocaml
        box_line_styled buf cols ~style:context.opening (dress text)
```

- [ ] **Step 4: Commit**

```bash
git add bin/masc_tui_render_chat.ml
git commit -m "fix(tui): tool clause dressing reopens the dim body it sits in"
```

### Task 3: 날짜 레일 recede + needle

**Files:**
- Modify: `bin/masc_tui_render_chat.ml:426-427`
- Test: `test/test_tui_keyboard_input.py:6994-7006`

- [ ] **Step 1: 스타일 변경**

```ocaml
  | Message_layout.Metadata (Message_layout.Timeline_break _) ->
      box_line_styled buf cols ~style:(Theme.info () ^ Ansi.bold) row.text
```

→

```ocaml
  | Message_layout.Metadata (Message_layout.Timeline_break _) ->
      (* The hour rail is a scrollbar landmark, not content: it stays, but
         recedes instead of holding the pane's brightest slot. *)
      box_line_styled buf cols ~style:(Theme.recede ()) row.text
```

- [ ] **Step 2: needle 갱신**

현재 (`test/test_tui_keyboard_input.py:6994-7006`):

```python
        styled_rail = re.compile(
            rb"\x1b\[[0-9;]*m\x1b\[1m"
            + "── ".encode()
            + re.escape(hour)
        )
        if styled_rail.search(drawn) is None:
            raise AssertionError(
                "Civil-hour rail was not drawn in semantic colour and bold "
                f"weight for {hour!r}: {drawn!r}"
            )
```

변경 — recede 팔레트 없음 평생은 dim(`\x1b[2m`), gray 허용, bold 부재를 검증:

```python
        styled_rail = re.compile(
            rb"\x1b\[(?:2|90)m"
            + "── ".encode()
            + re.escape(hour)
        )
        if styled_rail.search(drawn) is None:
            raise AssertionError(
                "Civil-hour rail did not recede (dim/gray) "
                f"for {hour!r}: {drawn!r}"
            )
        bold_rail = re.compile(
            rb"\x1b\[[0-9;]*m\x1b\[1m"
            + "── ".encode()
            + re.escape(hour)
        )
        if bold_rail.search(drawn) is not None:
            raise AssertionError(
                f"Civil-hour rail still held the bold slot for {hour!r}: {drawn!r}"
            )
```

- [ ] **Step 3: Commit**

```bash
git add bin/masc_tui_render_chat.ml test/test_tui_keyboard_input.py
git commit -m "fix(tui): the civil-hour rail recedes out of the brightest slot"
```

### Task 4: 시계 칸 recede

**Files:**
- Modify: `bin/masc_tui_message_layout.ml` — row 레코드(:95-149 일대)에 `gutter_clock_cells : int` 필드, `origin_gutter`(:1284-1393)에서 값 채움
- Modify: `bin/masc_tui_render_chat.ml:364-388` (`render_chat_row` 의 gutter 페인트)

- [ ] **Step 1: 기존 코드를 읽는다** — `origin_gutter`(:1284-1393), 특히 `Origin_inline` 의 `pad_clock`(:1294-1304)과 `filled = clock ^ label`(:1364), `gutter_label_at`(:1370). row 레코드 정의(:95-149).

- [ ] **Step 2: `gutter_clock_cells` 를 낸다**

row 레코드에 `gutter_clock_cells : int` 를 추가하고, `origin_gutter` 가 시계 칸(시계 5칸 + 띄움 1칸 = 6, 시계를 그리지 않는 모드/줄이면 0)을 채운다. `rows_of_entry`(:1395-1480) 등 row 를 만드는 모든 경로가 컴파일되게 채운다 (레코드 필드 추가라 컴파일러가 전부 가리킨다).

- [ ] **Step 3: 페인트에서 시계를 갈라 recede**

`bin/masc_tui_render_chat.ml:375-388` 의 `marked`(시계+마크) 분할:

```ocaml
          let marked = Message_layout.take_cells after_rail (at - rail_cells) in
          let label = Message_layout.drop_cells after_rail (at - rail_cells) in
```

를 시계 경계로 한 번 더 나눈다:

```ocaml
          let clock_cells = row.gutter_clock_cells in
          let clock = Message_layout.take_cells after_rail clock_cells in
          let after_clock = Message_layout.drop_cells after_rail clock_cells in
          let marked = Message_layout.take_cells after_clock (at - rail_cells - clock_cells) in
          let label = Message_layout.drop_cells after_clock (at - rail_cells - clock_cells) in
```

그리고 출력 조립에 `Theme.recede () ^ clock` 을 마크 앞에 끼운다 (기존 `rail ^ origin ^ bold ^ marked …` 모양 유지, 시계는 recede 로 감싸고 reset). 라벨은 이미 recede 다.

- [ ] **Step 4: Commit**

```bash
git add bin/masc_tui_message_layout.ml bin/masc_tui_render_chat.ml
git commit -m "fix(tui): the gutter clock recedes; the mark keeps the colour"
```

### Task 5: 채팅 브레드크럼 recede

**Files:**
- Modify: `bin/masc_tui_render_chat.ml:1896-1899`

- [ ] **Step 1: 변경**

현재:

```ocaml
let title =
  screen_title (Printf.sprintf " Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 chat" display_keeper_name)
```

`screen_title` (`bin/masc_tui_ansi.ml:586`)은 bold 를 입히는 공용 함수다. 이 호출지점만 recede 로:

```ocaml
let title =
  Printf.sprintf "%s Keepers \xe2\x96\xb8 %s \xe2\x96\xb8 chat%s"
    (Theme.recede ()) display_keeper_name Ansi.reset
```

(브레드크럼 needle `:6931` 등은 plain text 라 그대로 통과한다. keeper detail 쪽 `render.ml:6826` 의 bold 는 다른 표면이라 건드리지 않는다.)

- [ ] **Step 2: Commit**

```bash
git add bin/masc_tui_render_chat.ml
git commit -m "fix(tui): the chat breadcrumb is chrome, so it recedes"
```

### Task 6: PR 1 경계 — 빌드·실측·needle 확인·PR

**Files:**
- Evidence: `artifacts/tui-chat-hierarchy/pr1-after.txt` (새로 생성)

- [ ] **Step 1: 바이너리 빌드 (경계에서 한 번)**

```bash
dune build --root . bin/masc_tui.exe 2>&1 | tail -20
```

컴파일 오류가 나오면 고치고 커밋한다. 예상: `gutter_clock_cells` 추가에 따른 row 생성 경로 전수.

- [ ] **Step 2: macOS PTY 스위트 (needle 이 사는 가족)**

```bash
dune build --root . @test/runtest-test_tui_keyboard_input-chat-clarity --force
dune build --root . @test/runtest-test_tui_keyboard_input-memory-journal --force
```

각각 PASS 줄을 확인한다. 실패하면 콜론 뒤 바이트열로 실제 화면을 읽고 코드/needle 을 고친다 (추측으로 needle 을 고치지 않는다).

- [ ] **Step 3: 시각 증거 캡처**

`/tmp/masc_tui_capture.py` (이번 세션에서 만든 캡처 스크립트 — 없으면 다시 만든다: `test/test_tui_keyboard_input.py` 의 `chat_clarity_http_fixtures` 를 써서 채팅을 띄우고 화면 덤프) 를 돌려 after 를 저장한다:

```bash
python3 /tmp/masc_tui_capture.py
cp /tmp/masc_tui_capture/chat_main.txt artifacts/tui-chat-hierarchy/pr1-after.txt
cp /tmp/masc_tui_capture/chat_main.styles.txt artifacts/tui-chat-hierarchy/pr1-after.styles.txt
```

판정: 날짜 레일이 dim/gray 인가, `▶ YOU`·`● alpha` 본문만 full fg 인가, 스킬/도구 본문이 dim 인가.

- [ ] **Step 4: 푸시 + Linux CI 디스패치 (기다리지 않는다)**

```bash
git push -u origin tui-chat-hierarchy
gh workflow run test.yml --ref tui-chat-hierarchy -f suite=test_tui_keyboard_input-chat-clarity
gh workflow run test.yml --ref tui-chat-hierarchy -f suite=test_tui_keyboard_input-memory-journal
```

- [ ] **Step 5: PR 1 생성**

```bash
gh pr create --base main --head tui-chat-hierarchy \
  --title "fix(tui): brightness serves hierarchy — speech leads, chrome recedes" \
  --body "$(cat <<'EOF'
## 무엇
디자인: docs/design/2026-09-17-tui-chat-hierarchy-design.md (이 브랜치에 포함)

- 말(▶◀●) 본문만 터미널 전경 유지 — 일·저널·스킬 본문은 dim
- 날짜 레일: cyan+bold → recede (hairline 은 스크롤 방향타로 유지)
- 시계 칸 recede, 마크는 색 유지 (gutter_clock_cells 신설)
- 도구 배지 마젠타 폐기(상태색은 호출 마크가 답), 저널 배지 recede
- 브레드크럼 recede
- 마크다운 close 가 본문 스타일을 다시 열어 dim 이 bold/code 뒤에도 산다

## 증거
- artifacts/tui-chat-hierarchy/pr1-after.txt (PTY 실측, 100x30)
- test/test_tui_keyboard_input.py 날짜 레일 needle 갱신 포함
EOF
)"
```

- [ ] **Step 6: 적대적 리뷰 에이전트를 병렬로 붙인다** — PR 1 diff 를 읽고 (a) dim 본문이 새는 곳(bare link, code fence, diff fence), (b) NO_COLOR 동작, (c) `gutter_clock_cells` 가 0 이 아닌데 gutter 가 짧은 경우 take/drop_cells 안전성을 리뷰한다. 리뷰 결과는 도착하면 대응 에이전트를 붙인다. 기다리지 않고 PR 2 를 시작한다.

---

## PR 2 — 일 줄 접힘 (브랜치 `tui-chat-work-fold`, base: `tui-chat-hierarchy`)

### Task 7: 스킬 줄이 Ctrl-D 토글에 합류한다

**Files:**
- Modify: `bin/masc_tui_render_chat.ml:1188-1202` (커밋분), `:2166-2171` (라이브분)

- [ ] **Step 1: 새 브랜치**

```bash
git checkout -b tui-chat-work-fold tui-chat-hierarchy
```

- [ ] **Step 2: 커밋분 body 분기 변경**

`bin/masc_tui_render_chat.ml:1188-1202` 현재:

```ocaml
          | Message_skill _ -> (
              match message.me_skill_activity with
              | None -> message.me_text
              (* Always full, not tied to [msg_tool_visibility]: ... (1191-1199 주석) *)
              | Some activity ->
                  Keeper_chat_transcript.skill_rows ~full:true activity
                  |> String.concat "\n")
```

변경 — 요약 줄(state+name+action count)은 항상, ↳/proof/detail 은 Tools_full 에서만:

```ocaml
          | Message_skill _ -> (
              match message.me_skill_activity with
              | None -> message.me_text
              (* The summary line carries the fact this row exists for —
                 "delivered and used, N actions" — so it never folds. The
                 action list, proof line and detail ride the tool toggle:
                 Ctrl-D opens them, the resting pane stays one line. *)
              | Some activity ->
                  Keeper_chat_transcript.skill_rows
                    ~full:(state.msg_tool_visibility = Masc_tui_types.Tools_full)
                    activity
                  |> String.concat "\n")
```

- [ ] **Step 3: 라이브분도 같은 판정**

`:2166-2171` 의 `skill_rows ~full:true` 를 같은 식 `~full:(state.msg_tool_visibility = Masc_tui_types.Tools_full)` 로. (메모 키 `lem_tools`/`sbm_tools` 가 visibility 를 이미 잡고 있어 재계산은 공짜다.)

- [ ] **Step 4: Commit**

```bash
git add bin/masc_tui_render_chat.ml
git commit -m "fix(tui): skill detail rides Ctrl-D; the used-fact stays one line"
```

### Task 8: SKILL·TOOLS·THINKING 라벨 단어 삭제

**Files:**
- Modify: `bin/masc_tui_render_chat.ml:1104-1107` (`base_role_label_of`), `:2154`, `:2161`, `:2165` (라이브)

- [ ] **Step 1: 기존 코드를 읽는다** — `base_role_label_of` 전체(:1080-1130 일대)와 라이브 라벨 호출 세 곳.

- [ ] **Step 2: 단어를 지운다**

`Message_tool -> "TOOLS"`, `Message_skill _ -> "SKILL"`, `Message_thinking -> "THINKING"` 팔을 `""` 로. 라이브 `label "TOOLS"`/`label "SKILL"`/`label "THINKING"` 인자도 `""` 로. 칸(10칸)은 그대로 — `align_role_label` (`bin/masc_tui_message_layout.ml:947-965`)이 빈 라벨을 마크+패딩으로 그린다. 다른 팔(이름 라벨)은 손대지 않는다.

- [ ] **Step 3: Commit**

```bash
git add bin/masc_tui_render_chat.ml
git commit -m "fix(tui): the lane word is redundant with the lane mark, so it goes"
```

### Task 9: needle 갱신 (chat-clarity + autonomous-turn)

**Files:**
- Test: `test/test_tui_keyboard_input.py`

- [ ] **Step 1: 시나리오를 읽는다** — `chat_visibility_modes_interaction` (:7770 부근) 전체와 `autonomous_turn_history_interaction` (:6917 부근). 어느 키를 어느 순서로 누르고 무엇을 기다리는지 파악한다. 특히 chat-clarity 시나리오가 Ctrl-D 를 눌러 Tools_full 로 가는지 여부 — 가면 ↳/proof needle 은 그 뒤 프레임에서 잡는다.

- [ ] **Step 2: needle 교체**

확정된 교체 셋:
- `:7892` `re.search("◆\\s+SKILL".encode(), …)` → 라벨이 사라졌으므로 `re.search("◆\\s+전달됨".encode(), …)` (SGR 이 사이에 낄 수 있으면 기존 `:7850-7856` 의 토큰 분할 regex 방식을 따른다).
- `:6970` `("\u25a0 TOOLS".encode(), "the tool block header")` → `("\u25a0".encode(), "the tool block mark")`.
- `· THINKING` needle (autonomous-turn, :6969 부근) → 시나리오 fixture 가 아는 thinking 본문 첫 단어를 needle 로 (`autonomous_turn_history_fixture` :6520 일대에서 실제 문자열을 가져온다).
- ↳/proof needle (:7857-7859 `masc_fusion…observed`) → 시나리오에서 Ctrl-D 뒤로 옮기거나, compact 프레임에서는 부재를 검증.
- `:7896` `b"\x1b[1mci-red-attribution"` (이름 bold) 와 `:7818-7826` (`✗…masc_fusion…1200ms`) 는 그대로 통과해야 한다 — 바뀌면 코드가 잘못된 것이다.

바이트가 확신이 안 서면 Task 13 의 빌드 후 `--scenario` 로 한 번 돌려 실패 바이트열을 보고 확정한다 (needle 추측 금지는 여기서도 같다).

- [ ] **Step 3: Commit**

```bash
git add test/test_tui_keyboard_input.py
git commit -m "test(tui): needles follow the folded work rows and dropped lane words"
```

### Task 10: tui-chat-design 스킬 문서 동기화

**Files:**
- Modify: `.agents/skills/tui-chat-design/SKILL.md`

- [ ] **Step 1: 갱신**

- "왼쪽 여백의 순서" 절: 라벨 칸 설명에 "도구·스킬·생각 줄은 라벨 단어를 쓰지 않고 마크만 둔다 — 마크가 이미 레인을 말한다" 를 추가.
- 시계 단락: "시계는 recede 로 눌려 있고 마크만 색을 쓴다" 추가.
- 새 단락 "끝난 일은 접힌다": 기본 밀도에서 스킬은 요약 한 줄(전달·사용 사실은 남음), ↳/proof/detail 은 Ctrl-D 뒤. 도구는 Tools_compact 기본(≤2 호출은 호출별 줄, 3개 이상은 inventory 헤더, 실패·진행 중은 독립 줄). 날짜 레일과 브레드크럼은 recede.
- "말한 사람 — speaker_mark" 표는 그대로 (마크 변경 없음).

- [ ] **Step 2: Commit**

```bash
git add .agents/skills/tui-chat-design/SKILL.md
git commit -m "docs(tui): the chat design note matches the folded, receded pane"
```

### Task 11: PR 2 경계 — 빌드·실측·증거·PR

**Files:**
- Evidence: `artifacts/tui-chat-hierarchy/pr2-after.txt`

- [ ] **Step 1: 빌드**

```bash
dune build --root . bin/masc_tui.exe 2>&1 | tail -20
```

- [ ] **Step 2: PTY 스위트**

```bash
dune build --root . @test/runtest-test_tui_keyboard_input-chat-clarity --force
dune build --root . @test/runtest-test_tui_keyboard_input --force
```

메인 산책(keyboard)은 `■ TOOLS`·`✗ tool_execute · 1200ms` needle 을 품는다. 둘 다 PASS 확인. 실패 시 바이트열을 읽고 고친다.

- [ ] **Step 3: 증거 캡처 + 줄 수 판정**

```bash
python3 /tmp/masc_tui_capture.py
cp /tmp/masc_tui_capture/chat_main.txt artifacts/tui-chat-hierarchy/pr2-after.txt
```

성공 조건 판정 (스펙 §9): 8월 히스토리 블록이 ≤2줄 인가 (`╶ ◆ ci-red-attribution · 씀…` + `╶ ■ ✗ masc_fusion · 1.2s` 모양), `SKILL`/`TOOLS` 단어가 화면에 없는가, Ctrl-D 후 proof 가 다시 나오는가 (캡처 스크립트에 Ctrl-D 키 전송 단계를 추가해 pr2-after-tools-full.txt 도 저장).

- [ ] **Step 4: 푸시 + Linux CI 디스패치 (기다리지 않는다)**

```bash
git push -u origin tui-chat-work-fold
gh workflow run test.yml --ref tui-chat-work-fold -f suite=test_tui_keyboard_input-chat-clarity
gh workflow run test.yml --ref tui-chat-work-fold -f suite=test_tui_keyboard_input
```

- [ ] **Step 5: PR 2 생성 (stacked)**

```bash
gh pr create --base tui-chat-hierarchy --head tui-chat-work-fold \
  --title "fix(tui): finished work folds to one line; the lane word goes" \
  --body "$(cat <<'EOF'
## 무엇
Stacked on PR 1. 디자인 §4 구현.

- 스킬 ↳/proof/detail 이 Ctrl-D(Tools_full) 뒤로 — 요약 줄(전달됨, 도구 씀 · 이름 · N action)은 항상 남는다 (render_chat.ml:1191 의 "사실은 화면에" 계약 유지)
- SKILL/TOOLS/THINKING 라벨 단어 삭제 — 마크가 레인을 답, 칸은 유지
- needle 갱신 + tui-chat-design 문서 동기화

## 스펙과의 차이 (계획에 기록, 사용자 확인됨)
- 혼합 체인 대신 역할별 한 줄 (마크 칸 계약)
- 3개 이상 호출 블록은 기존 카운트 inventory 유지

## 증거
- artifacts/tui-chat-hierarchy/pr2-after.txt / pr2-after-tools-full.txt
EOF
)"
```

- [ ] **Step 6: 적대적 리뷰 에이전트 병렬** — (a) 스킬 토글 합류로 "전달만 됨 vs 쓰임" 이 정말 여전히 한눈에 보이는지, (b) 라이브 턴에서 진행→완료 전환 시 줄 수 변화가 뷰포트를 점프시키는지, (c) needle 갱신이 검증을 약하게 만들지 않았는지. 리뷰 도착 시 대응 에이전트 병렬.

---

## Self-Review 결과 (계획 작성 후 점검)

- **스펙 커버리지**: L0 기존 재사용(태스크 없음, 근거 기술), L1 변경 없음, L2 Task 3-4, L3 Task 1-2·7-8, L4 Task 1, L5 Task 7(도구는 기존 Tools_full), L6 Task 5, §4.2-4.3 기존 동작 확인(증거 태스크에서 판정), §6 NO_COLOR/좁은 폭 Task 6·11 리뷰·증거, §7 검증 Task 6·11. 차이 2건은 위에 명시.
- **플레이스홀더**: "읽는다" 단계는 파일:줄을 박았고, 바꿀 코드는 보인 코드를 그대로 적었다. needle 교체 중 시나리오 의존 2건(:6969 thinking 본문, ↳/proof 재배치)은 읽고 확정하는 절차를 명시했다.
- **타입 일관성**: `Tools_full` 참조는 `Masc_tui_types.Tools_full`, `skill_rows ~full:bool`, `gutter_clock_cells : int` — Task 4 의 레코드 필드명과 페인트 참조가 일치.
