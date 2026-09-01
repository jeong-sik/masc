---
rfc: "tui-operator-ia"
title: "TUI 정보 구조 재설계 — 18탭을 숫자 키 10개로 접고, Keeper 워크벤치를 중심 화면으로"
status: Draft
created: 2026-09-01
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: ["RFC-tui-server-lifecycle"]
---

# RFC: TUI operator IA (tui-operator-ia)

## 0. Summary

TUI 는 2기 캠페인(docs/design/tui/TUI-ROADMAP.md)으로 대시보드의 모든 section 을
터미널로 옮기는 데 성공했다. 그 대가로 **최상위 탭 18개**가 남았다. 운영자
(2026-09-01)가 실제 화면 18장을 놓고 판정한 결론은 두 가지다.

1. **위계가 없다.** 탭 18개가 같은 급으로 나열되고, 이동 수단은 Tab 순환과
   팔레트뿐이다 (#31867). 2행짜리 화면(Repos, Connectors)이 Board·Planning 과
   같은 무게를 갖고, "lane" 이라는 말이 세 화면에서 서로 다른 뜻으로 쓰인다
   (§6-1). 게다가 Harness 와 Changes 는 Tab 순환으로도 팔레트로도 닿지 못하고
   문맥 키 하나가 유일한 경로다 (types.ml:3487-3490).
2. **핵심 데이터가 숨어 있다.** 운영자가 물은 것 — "Skill/Tool 트리거 구분",
   "async 도구 대기 현황", "diff 는 어디서", "memory 카테고리", "다음 턴 컨텍스트
   주입과 용량" — 은 대부분 **이미 저장되고 일부는 이미 그려진다.** 컨텍스트
   인스펙터는 `/context`·Ctrl-X 뒤의 모달로(masc_tui.ml:5189, :1266), diff 는
   세 렌즈에 쪼개져 서로 다른 정보량을 주고(§6-4), Skill/Fusion/Keeper 구분은
   **Compact 접힘에만 있고 Full 에서 오히려 사라지며**(transcript.ml:427-441,
   :459), async 큐는 Tools 다섯 pane 중 하나에만 있고 채팅과 조인되지 않는다.
   데이터의 문제가 아니라 IA 의 문제다.

이 RFC 는 (A) 최상위 탭을 숫자 키와 1:1 인 10개로 접는 구조, (B) Keeper 상세를
채팅·호출·diff·컨텍스트·메모리를 한 곳에서 여는 **워크벤치**로 승격하는 설계,
(C) 거기까지 가는 PR 절단선을 정한다.

이 방향은 이미 코드와 저장소에 선례가 있다. Verification·Harness 는 Planning 의
자식 모드로 접혀 있고(`surface_ring_index`, types.ml:1211-1223; 순환 키 주석
masc_tui.ml:13641-13645), 웹 대시보드는 상단 탭 스트립을 이미 없애고 좌측 레일
단일 내비로 통합했다(docs/design/keeper-v2-v12-gap-current.md:24). 이 RFC 는 그
패턴의 확대 적용이다.

## 1. 현재 인벤토리 (2026-09-01 실측, v0.28.0 f4fa884)

`surface_ring` (bin/masc_tui_types.ml:1186-1205) 의 18탭, 표기 순서 그대로:

| # | 탭 | 갱신 | 내용 | 판정 |
|---|---|---|---|---|
| 1 | Overview | 폴링(briefing 은 모든 화면에서 매 틱) | 헬스 + Attention + 세션 이벤트 + Task 목록 | fleet home 으로 개편 |
| 2 | Acting | SSE | 전 Keeper 턴/호출 피드 | 유지 (Activity 로) |
| 3 | Keepers | 폴링+진입 | 함대 표 + 상세/채팅/로그/호출 | 워크벤치로 승격 |
| 4 | Memory | 진입 | Keeper별 스냅샷 건강 통계 | 사실 브라우저로 재정의 (§3.4) |
| 5 | Lanes | 진입 | standalone 서비스 레인 | Runtime 서브탭으로 흡수 |
| 6 | Approvals | 폴링(전 화면) | 승인 + 질문 대기 | Inbox 로 확장 |
| 7 | Board | 폴링 | Keeper 게시판 | 유지 |
| 8 | Planning | 폴링 | Goals/Task Review/Verdicts (이미 3탭 허브) | 유지 — Fusion·Schedules 수용 |
| 9 | Schedules | 진입 | wake 스케줄 | Planning 서브탭 |
| 10 | Fusion | 진입 | fusion 런 | Planning 서브탭 |
| 11 | Repos | 진입 | 등록 저장소 2행 | Workspace 로 병합 |
| 12 | Code | 진입 | 파일 브라우저 + git diff/log | Workspace 로 병합 |
| 13 | Connectors | 진입 | 채널 4행 + bind/unbind | Runtime 서브탭 |
| 14 | Runtime | 진입 | keeper 레인/슬롯/프로브 | 유지 — 흡수 수용처 |
| 15 | Config | 진입(pane별) | toml/models/params/prompts/themes | 유지 — Registry pane 수용 |
| 16 | Resources | 진입(MCP JSON-RPC) | MCP 리소스 카탈로그 | Config Registry 로 |
| 17 | Tools | 진입 | surface/async/receipts/usage/catalog 5-pane | 분해 (§3.2, §3.1) |
| 18 | Logs | 폴링 | 시스템 로그 | Activity 로 통합 |

링 밖 숨은 화면 3개는 `surface_ring_index` 가 부모로 접는다: Verification·
Harness → Planning (`v` 순환), Changes → Keepers (`f`). **Harness 와 Changes 는
팔레트에도 없다.** 참고로 docs/TUI-GUIDE.md:9 의 링 설명은 낡았다 — 19개라
적었고 Memory 가 빠졌으며 Harness·Changes 를 링에 넣어 놨다. 이 PR 에서 고친다.

화면 캡처 자동화(scripts/capture-tui-screenshots.py)는 18개 중 5개 화면만
찍는다(docs/screenshots/tui/*/surfaces/ — 01-overview, 02-keepers, 03-lanes,
05-approvals, 06-acting). 롱테일 화면은 회귀 증거조차 없다.

## 2. 문제 정의 — 운영자 질문과 현재 응답 위치

이 제품의 성공 조건(연속 턴, 기억 연속성, Keeper 간 통신, 출력 목적지 판단)을
운영자가 **화면에서 검증할 수 있는가**가 TUI 의 존재 이유다. 실측한 응답 위치:

| 운영자 질문 | 현재 위치 | 문제 (file:line) |
|---|---|---|
| 지금 무슨 결정을 기다리나 | Approvals + Overview Attention + footer | `/api/v1/operator` 는 이미 전 화면에서 매 틱 폴링된다(masc_tui.ml:5657-5674) — 데이터는 있는데 합산 표면이 없다 |
| Skill 트리거인가 Tool 인가 | Compact fold 의 kind 요약뿐 | kind 분류(transcript.ml:412-423)를 읽는 곳이 `compact_activity_kinds` 하나(:427-441, 호출 :459) — **Full 로 펼치면 사라진다**. 분류 자체도 도구 이름 접두사 문자열 매칭이고 Acting 에 복붙돼 있다(acting.ml:128-133) |
| 이 호출이 뭘 돌려줬나 | 없음 | `Live.Tool_result` 가 `{occurrence; execution_id}` 만 나른다(live.mli:68-71) — **도구 결과 본문은 디코드조차 안 된다** |
| async 도구 뭐가 돌고 뭘 대기 | Tools > async runs | 채팅·Acting 모듈에 `async` 0회. 양쪽 다 `request_id`/`keeper` 를 들고도 조인 안 됨 |
| diff 는 어디서 보나 | 채팅 Ctrl-D Full · Changes · Repos `d` | 세 렌즈의 정보량이 다르다 — `fc_turn`/`fc_task_id` 가 Changes 엔 있고(render.ml:9080-9082) 채팅 diff 엔 없다(diff.ml:322-330). 부분 커버리지 필드(missing/ambiguous_execution_ids, diff.mli:24-30)는 렌더 지점 자체가 없다 |
| 다음 턴에 뭘 알고 시작하나, 용량은 | `/context`·Ctrl-X 모달 | 데이터는 풍부하다 — 토큰 비율 바, 구성요소별 바이트 분해, prompt block 원문, included_by/retention 트리(render.ml:13241-13545). 문제는 (a) 발견성, (b) "마지막으로 보낸 입력"의 사후 판독만 있다는 것 |
| memory 에 뭐가 쌓였나, 카테고리는 | Memory 탭(개수 통계만) | store 에는 닫힌 8분류(`Code_change…Lesson`, keeper_memory_os_types.mli:41-49) + origin + reinforcement + first/last_seen 이 전부 있는데 health JSON 이 **하나도 내보내지 않는다**(server_dashboard_http_keeper_memory_health.ml:341-437) |
| 함대 시간축에 무슨 일이 | Acting(SSE) · Logs(REST) · Overview 세션 이벤트(로컬 146곳) | 같은 사건이 세 갈래에 다른 모양으로 나타나고 조인되지 않는다 |

## 3. 설계

### 3.1 최상위 10탭 — 숫자 키와 1:1

18탭을 10탭으로 접는다. 10개는 우연이 아니라 제약이다: `1`~`9`,`0` 이 각 탭으로
**직행**한다 (#31867 의 답). Tab 순환·팔레트·`?` 도움말은 유지.

| 키 | 탭 | 흡수하는 것 | 운영자 질문 |
|---|---|---|---|
| 1 | Overview | fleet 계기판, Memory 건강 롤업 | 함대가 지금 어떤 상태인가 |
| 2 | Inbox | Approvals + Questions + Attention + completed-unread | 내 결정을 뭐가 기다리나 |
| 3 | Keepers | Changes, Keeper logs/calls, `/context` 모달, Tools 의 per-Keeper pane | 이 Keeper 가 뭘 했고 왜, 다음 턴에 뭘 아나 |
| 4 | Activity | Acting + Logs | 함대 시간축에서 무슨 일이 있었나 |
| 5 | Board | (유지) | Keeper 들이 서로 뭐라 하나 |
| 6 | Planning | Verification·Harness(기존) + Fusion + Schedules | 작업·판정·자동화가 굴러가나 |
| 7 | Memory | (재정의 — §3.4) | 무엇이 기억됐고 어떤 분류인가 |
| 8 | Runtime | Lanes + Connectors | 기반(레인·런타임·채널)이 살아있나 |
| 9 | Workspace | Repos + Code | 파일과 저장소는 어떤 상태인가 |
| 0 | Config | Resources + Tools 의 catalog/usage/receipts (Registry pane) | 무엇이 설정·등록돼 있나 |

각 흡수의 성격은 다르며, 뭉뚱그리지 않는다:

- **Lanes → Runtime**: "lane" 은 지금 세 화면에서 세 데이터다(§6-1). 병합이
  아니라 Runtime 아래 서브탭 세 축(서비스 레인 / keeper 레인·슬롯 / 전체
  런타임)으로 가른다. Runtime 은 이미 `Runtime_lanes`/`Runtime_all` 서브모드가
  있어(types.ml:508-512) 자리도 있다.
- **Approvals → Inbox**: 새 요청이 필요 없다 — `/api/v1/operator` 는 이미 전
  화면 폴링이다. Attention(briefing `ov_attention_items`), Keeper 질문, 외부
  멘션, "턴 끝났는데 안 본" 통지를 한 큐로 모으고 waiting-for-input 을 최상단
  정렬한다. footer 의 "Awaiting you N" 과 같은 수를 가리킨다.
- **Activity = Acting + Logs**: 이벤트 갈래는 셋이다(§6-3). Acting(SSE)과
  Logs(REST)를 스코프/레벨 필터로 한 지붕에 두되, Overview 의 세션 이벤트는
  성격이 다르다(TUI 프로세스 자기 로그) — Overview 에 남긴다.
- **Resources + Tools catalog → Config Registry**: 데이터 중복이 아니다(경로가
  REST vs MCP JSON-RPC 로 완전 분리). 근거는 "둘 다 등록 카탈로그이고 조회
  빈도가 낮다"는 성격 일치다. Tools 의 다섯 pane 은 갈라진다: available →
  워크벤치 Surface pane, async runs → 워크벤치 스트립 + Activity, receipts/
  usage/all tools → Config Registry.
- **Overview 개편**: Antigravity Manager 역할의 fleet home. Keeper 행마다
  4상태 칩(working / **waiting-for-input** / completed-**unread** / idle·failing),
  context% (기존 `Masc_tui_context_state` 로컬 계산 재사용, HTTP 불필요),
  오늘 비용, 마지막 활동 나이. Task 수십 행은 Planning 소관으로 내려간다.

### 3.2 Keeper 워크벤치 — 상세 표면의 승격

Keepers 상세를 pane 탭 허브로 만든다 (기존 detail `[`/`]` 순환의 확장):

```
Keepers ▸ analyst ▸ [Chat] Calls  Changes  Context  Memory  Surface  Schedule  Logs
```

- **Chat**: 접힌 tool 행이 kind 를 입는다 — "Ran 2 tools" 대신
  `▮ Skill background-snapshot ✓ · Tool masc_board_stats ✓ 6.7s`. 단, 지금의
  kind 는 도구 이름 접두사 문자열 매칭이다(transcript.ml:412-423). 접두사
  매칭을 늘리지 않는다 — **생산자가 typed kind 를 wire 에 싣게 하고**(서버
  PR), TUI 는 그것을 그린다. Full 모드에서도 kind 를 유지한다.
- **Tool 행의 잃어버린 필드**: `args`(subject 로 접힌 원문), `execution_id`,
  결과 본문을 Full 모드에서 드러낸다. 결과 본문은 디코드부터 필요하다
  (live.mli:68-71 — 서버가 이미 보내는지, artifact 참조인지 확인 후 결정).
- **Async strip**: 헤더 아래 한 줄 — 이 Keeper 의 async 실행 중/대기 수와
  이름·경과. `/api/v1/async-requests` 가 `request_id`·`keeper` 를 이미 주므로
  필터만 하면 된다.
- **Context pane**: `/context` 모달의 세 탭(Composition·Prompt blocks·Input
  map)을 pane 으로 승격. 발견성이 핵심 — footer 힌트와 pane 탭에 상시 노출.
- **Changes pane**: 숨은 Changes 화면이 이 pane 이 된다. 채팅 diff 에도
  `fc_turn`/`fc_task_id` 귀속과 부분 커버리지 보고를 붙인다.
- **Memory pane**: 이 Keeper 의 사실 목록(§3.4 의 per-keeper 뷰).
- **Surface pane**: Tools 의 "Effective Keeper Surface" 이동.

### 3.3 하드컷 원칙

surface variant 와 `surface_ring` 항목을 지우고, 팔레트 사전·`?` 도움말·PTY
스위트·TUI-GUIDE 를 같은 PR 에서 갱신한다. 별칭·리다이렉트·"이사갔습니다"
안내를 남기지 않는다. 흡수되는 화면의 렌더러와 로더는 이동이지 삭제가 아니다 —
데이터 표면은 전부 살아남고 주소만 바뀐다. TUI-ROADMAP.md L63 의 "화면 추가 =
템플릿 복제 + surface variant 삽입" 성장 모델은 이 RFC 로 종료된다(새 정보는
기존 10탭 아래 pane/서브탭으로 들어간다).

### 3.4 Memory 탭 재정의 — 서버 격차부터

지금의 Memory 는 개수 통계표다. store 에는 닫힌 8분류
(`Code_change, Fact, Preference, Blocker, Goal, Constraint, Validated_approach,
Lesson` — keeper_memory_os_types.mli:41-49)와 사실별 origin
(`Authored|Injected|Legacy`), reinforcement, first/last_seen, source-bound 의
`file_source{path;sha256}` 와 무효화 사유까지 전부 있는데, health 엔드포인트가
개수만 내보낸다. 재정의 순서:

1. (서버 PR) 사실 단위 조회 엔드포인트 — 카테고리·origin·시각 포함. 기존
   `/api/v1/keepers/<name>/memory-journal` 과의 관계를 먼저 확인하고 겹치면
   확장, 아니면 신설.
2. (TUI PR) Memory 탭 = 사실 브라우저: Keeper 선택 → 카테고리 필터 → 사실
   본문·강화 횟수·출처·무효화 사유. 건강 통계는 요약 스트립으로.
3. TUI 는 분류를 지어내지 않는다 — 서버가 준 typed 분류만 그린다.

## 4. PR 절단선

각 PR 은 독립 머지 가능하고, 화면 이동 PR 은 PTY 시나리오·가이드·팔레트 갱신을
같은 PR 에 싣는다. 순서는 의존이 아니라 위험 오름차순이다.

| PR | 내용 | 성격 |
|---|---|---|
| A | 이 RFC + TUI-GUIDE.md:9 정정 | docs |
| B | ~~Acting turns scope 누수~~ (#32197 머지됨) + 유령 turn 행(#32208) | fix |
| C | 숫자 키 `1`~`0` 직행 + 팔레트에 숨은 화면 등재 | nav, 무파괴 |
| D | Connectors → Runtime 서브탭 (최소 흡수로 패턴 확립) | 흡수 1 |
| E | Lanes → Runtime 세 축 서브탭 | 흡수 2 |
| F | Schedules·Fusion → Planning 서브탭 (`v` 순환 확장) | 흡수 3 |
| G | Repos + Code → Workspace | 흡수 4 |
| H | Resources·Tools catalog/usage/receipts → Config Registry | 흡수 5 |
| I | Approvals → Inbox (Attention·질문 합류, 4상태 정렬) | 확장 |
| J | Overview fleet home (칩·계기판, Task 목록 Planning 이관) | 개편 |
| K | Acting + Logs → Activity | 통합 |
| L | 워크벤치 1: pane 허브 골격 + Context/Changes/Surface 승격 | 워크벤치 |
| M | 워크벤치 2: chat kind 상시화(서버 typed kind 선행) + async strip | 워크벤치 |
| N | Memory 서버 export → 사실 브라우저 | 서버+TUI |

C~H 는 각각 작고 기계적이다(`surface_ring` 제거 + `surface_ring_index` 부모
등재 + 서브탭 키 + 문서/PTY). I 부터가 설계 작업이다.

## 5. 경쟁 TUI 조사 (2026-09-01 웹 확인)

8개 제품 전수 확인: pi(pi.dev), Codex CLI, Claude Code, Antigravity 2.0, Orca,
Hermes Agent, OpenClaw, Kimi Code CLI. 요지만 남긴다.

**단일 에이전트 TUI 4종(pi·Claude Code·Hermes·Kimi)은 같은 모양으로 수렴했다**:
단일 스트림 + 접힌 tool 행 + 상태 바. 차별점은 pi 의 `/tree` 세션 분기, Hermes
의 색상 임계 context 게이지(초록<50% ~ 빨강≥95%)와 `/verbose` 4단계, Claude
Code 의 메시지 큐잉과 Ctrl+O transcript 토글("Called slack 3 times" 한 줄
접기). Codex CLI 는 2026-08 에 agents dashboard 를 추가해 단일 스트림에서
2-표면 구조로 이동 중이다.

**함대 감독 IA 를 실제 구현한 것은 Antigravity 와 Orca 둘뿐이다**:

- Antigravity 2.0: Editor ↔ Agent Manager 2-표면. 핵심은 **Inbox** — 전
  에이전트의 상태 변화·승인 요청을 한 큐로 모아 에이전트별 채팅 폴링을 없앤다.
  에이전트는 Artifacts(계획·diff·walkthrough·스크린샷)를 의무 생성하고
  운영자는 산출물에 코멘트를 달아 실행 중 궤도를 수정한다.
- Orca: worktree별 병렬 에이전트 + 터미널 탭의 **4상태 칩**
  (working / waiting-for-input / completed / **completed-but-unread**) +
  Notifications & Inbox. "끝남"과 "사람이 봤음"을 분리한다.

**전이하는 패턴 7**: ① fleet 표면 ↔ 개별 상세 표면 분리 ② 통합 Inbox ③ 4상태
keeper 칩 ④ 도구 활동의 단계적 공개(함대 1줄 → 상세 tool 행 → 전체 trace)
⑤ 산출물 단위 리뷰 + 코멘트의 다음 턴 주입(masc 의 evidence·verifier lane 과
정합) ⑥ 계기판의 전치 — 단일 상태 바가 아니라 keeper별 컬럼 ⑦ 큐잉과 steering
의 제스처 분리.

**안티패턴 3**: ① 여러 에이전트를 한 선형 스트림에 인터리브(승인 프롬프트가
스크롤에 매장) ② pane-per-agent 멀티플렉서 = 감독이라는 착각(Orca 조차 상태
칩과 Inbox 로 보완) ③ 관찰면을 웹 대시보드로 밀어내기(TUI 가 승인·상태·증거
리뷰를 자체 완결 못 하면 상태가 두 표면에 분열).

**전이 불가(단일 에이전트 전제)**: 단일 context 게이지 상태 바, 스트림 내 tool
행 접기(개별 keeper 상세에서만 유효), 세션 트리 분기(자율 keeper 에는 replay
용도만).

## 6. 코드 매핑 근거 (2026-09-01 전수 조사)

1. **"lane" 삼중 의미**: 최상위 Lanes 는 `/api/v1/dashboard/standalone-lanes`
   (masc_tui.ml:3624-3631), Keepers 목록은 `/api/v1/keepers/composite`
   (:3605-3610), Runtime 서브모드는 `/api/v1/runtime/resolved`(:3202). Runtime
   내부 두 서브모드는 "같은 스냅샷, 다른 질문" 주석이 있지만(types.ml:508-512)
   최상위 Lanes 와의 관계는 어디에도 설명이 없다.
2. **Approvals 는 이미 전역 폴링**: `load_http_surfaces`(masc_tui.ml:5657-5674)
   가 화면과 무관하게 `/api/v1/operator` 를 부른다 — `surface_needs` 절약
   원칙(types.ml:1256-1259)의 유일한 예외. Inbox 통합에 새 요청이 필요 없다.
3. **이벤트 세 갈래**: Overview 패널(`add_event` 146곳, TUI 로컬) / Acting
   (SSE observer) / Logs(`/api/v1/dashboard/logs`). 조인 없음.
4. **diff 세 렌즈의 정보량 차이**: 채팅 diff 는 `execution_id` 조인
   (diff.ml:107-114)에 12행 미리보기·블록당 3개 제한, Changes 는
   `fc_turn`/`fc_task_id` 표시, Repos `d` 는 git status/diff. 부분 커버리지
   필드는 렌더 지점이 없다(diff.mli:24-30).
5. **흡수 메커니즘은 이미 있다**: `surface_ring` 에서 빼고 `surface_ring_index`
   (types.ml:1211-1223)에 부모를 적고 순환 키를 주면 된다 — Planning 의 `v`
   순환(masc_tui.ml:13638-13650)이 작동 선례.
6. **중복이 아닌 것**: Resources(MCP JSON-RPC)와 Tools(REST)는 데이터 경로가
   분리돼 있다 — Registry 병합의 근거는 성격(카탈로그)이지 중복 제거가 아니다.
   Planning 과 Board 도 데이터가 겹치지 않는다(순환 인접이 혼동의 원인일 뿐).

## 7. 하지 않는 것

- 렌더 기반 교체(ANSI 직접 → Notty 등)는 이 RFC 밖. ROADMAP 의 "화면이 다
  붙은 뒤 측정으로 결정" 조항을 따르되, 뷰 통폐합이 전제를 바꾸므로 통폐합 후
  재측정한다.
- #32098 의 화면별 7단계 실측은 살아남는 화면에 그대로 적용된다. 이 RFC 는
  어떤 화면이 살아남는지를 정한다.
- 문자열 접두사 kind 분류의 확대. 상시 kind 표시는 생산자 typed kind 가 wire
  에 실린 뒤에 한다 (§3.2).
