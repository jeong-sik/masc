---
rfc: "tui-operator-workbench"
title: "TUI 작업대 — 같은 대상을 따라가며 원본과 판정을 읽는다"
status: Draft
created: 2026-09-26
updated: 2026-11-09
author: dancer + claude
supersedes: []
superseded_by: null
related: ["tui-measured-operator-home", "tui-single-input-decoder", "0459", "0462", "0503", "0511"]
implementation_prs: []
---

# TUI 작업대

이 문서는 공통 조작의 제안과 명시적인 운영자 결정을 구분한다. 구현 목록은
[화면 지도](../design/tui/SCREENS.md), 사용 방법은 [TUI 가이드](../TUI-GUIDE.md),
개발·검증 절차는 [제품 계약](../constitution.xml)이 정본이다.
제안이 적혀 있다는 사실은 승인이나 구현 완료를 뜻하지 않는다.

## 목적지

최상위 메뉴는 [운영자 홈 결정](RFC-tui-measured-operator-home.md)의
Dashboard, Work, Keepers, Usage, Board, Workspace, System을 따른다.
하위 화면은 해당 목적지 안에서 찾고, 팔레트는 같은 목적지의 별칭을 검색어로 묶는다.
화면·Task·게시글을 한 목록에 늘어놓는 대신, 주요 목적지를 먼저 보여 주고 검색으로 좁힌다.

Work는 목표·Task·제출 증거·판정을, Keepers는 대화·호출·기억·변경 근거를 소유한다.
Runtime의 모델 배치, Features의 기능 상태, Plugins의 설치·연결은 서로 다른 질문이다.
같은 단어를 쓴다는 이유만으로 데이터나 권한을 합치지 않는다.

## 같은 Keeper에서 근거까지

- 대화·호출·Changes·Memory·Context를 오가도 열린 대상의 Keeper를 보존한다.
  목록 커서를 옮기는 행동만으로 이미 열린 대화나 Context의 대상을 바꾸지 않는다.
- 도구 결과의 수신, 요청 수락, 실행 완료, Task 검증은 서로 다른 사실이다.
  실패·진행·미반환·권한 대기는 기본 보기에서도 남긴다.
- async 요청은 생산자가 준 요청·Keeper·호출·턴 identity로 연결한다.
  귀속을 모르면 미확인으로 표시하고 과거 실패를 현재 대기 건수에 더하지 않는다.
- Changes는 변경을 만든 Task·턴·호출로 연결한다. 부분 수집과 읽기 실패를 보존하며,
  펼침과 복사는 같은 원문을 읽는다. Git의 현재 diff로 기록된 편집을 대체하지 않는다.
- Memory는 생산자의 분류·출처·무효화 이유를 사용한다.
- Context의 마지막 관측 입력은 trace·turn·관측 시각·포함 근거·정확한 바이트를 가진다.
  다음 입력은 생산자가 실제 조립한 대상과 revision을 제공할 때만 별도 관측으로 연다.
  준비 전 상태를 현재 facts 합계나 토큰 추정으로 채우지 않는다.
- Esc는 열린 선택창·상세부터 닫고, 입력 초안과 원래 선택·스크롤을 보존한다.

구체적인 읽기 소유권과 대화 표시 규칙은
[TUI 설계 스킬](../../.agents/skills/tui-chat-design/SKILL.md),
[원본 도구 결과 읽기](../../bin/masc_tui_chat_call_reader.mli),
[Context 상태](../../bin/masc_tui_context_state.mli)를 따른다.

## 명시적인 운영자 결정

다음은 2026-09-28 운영자 결정이다. 구현 완료 목록이 아니다.
폭은 각 화면에 같은 숫자를 복사하지 않고 실제 본문·패널의 레이아웃 값으로 계산한다.

| 항목 | 결정 |
|---|---|
| D2 · 옆 칸 | 움직이는 것과 최근 활동을 보여 준다. 필요한 본문 폭을 확보한 경우에만 연다. 채팅에도 허용한다. |
| D11 · 포커스 | 입력을 받는 영역의 바깥 경계를 `━`·`┃`로 구분한다. 색이 없어도 구분돼야 한다. 도식 내부의 선과 영역 바깥 경계는 다른 좌표다. |
| D12 · 폭 기준 | Dashboard·Work·Usage라는 화면 이름만으로 옆 칸을 끄는 예외 목록을 추가하지 않는다. 본문 폭을 기준으로 한다. |
| D13 · roster | 채팅 roster는 자체 본문 최소 폭을 유지한다. 옆 칸과 roster를 함께 둘 수 없으면 roster부터 접는다. |
| D14 · 제목 | 최상위 화면 이름은 탭 띠가 소유한다. 본문 머리에는 하위 경로와 상태를 두고 `MASC <화면 이름>`을 반복하지 않는다. |
| D15 · Agenda | `; Awaiting you·N` 표기를 유지하고 영역 경계로 입력 줄과 구분한다. |
| D16 · 옆 칸 경계 | 배경 틴트와 세로선을 함께 둔다. 포커스 때 세로선만 굵어진다. |

폭과 실제 배치의 정본은 [활동 패널](../../bin/masc_tui_acting_pane.ml),
[roster](../../bin/masc_tui_roster_pane.ml), [레이아웃](../../bin/masc_tui_render_prim.ml)이다.
현재 코드가 위 결정 전체를 구현했다고 가정하지 않는다.

## 남은 제안

아래 항목은 소스·진행 중인 PR·사용 사례를 다시 확인한 뒤 작은 변경으로 진행한다.

- Keeper 상세는 대화·호출·변경·기억을 쉽게 찾게 하고, 미연결 서비스·닫힌 예약은 접는다.
  [Keeper 상태](RFC-0503-keepers-list-shows-a-failed-last-turn-apart-from-the-activity-now.md)와
  [진행 중인 개선 범위](RFC-0511-the-rest-of-the-keeper-pulse-sheet-lands-as-four-independent-stacks.md)를 먼저 확인한다.
- Work의 요청·Task 검증·Goal 확인을 한 진입점에서 찾게 한다. 이들을 합친다고 서로 다른
  승인 권한·종료 조건이나 원장을 하나로 바꾸지 않는다. Task 취소는 즉시 수행하는 전이다.
- Memory·Schedules·Fusion의 재배치는 사용자가 하는 일과 실제 진입 경로를 확인한 뒤 판단한다.
  Keeper별 읽기와 전체 목록이 같은 화면이라고 가정하지 않는다.
- 설정 목록은 연결된 항목과 현재 값을 먼저 읽게 하고, 내부 조립 조각·원본 JSON은 상세로 둔다.
- 열을 접는 순서와 늘어나는 열은 표의 타입 있는 설명으로 관리한다. 더 좁아진 뒤의 쌓기는
  [좁은 화면 제안](RFC-tui-narrow-mode.md)을 따른다.
- 원문 복사와 참조 복사를 구분하고, 선택한 원본에서 복사한다. OSC 52 전송을 클립보드 수신으로
  표현하지 않는다. 키를 바꿀 때는 기존 키 레지스트리와 승인 동작을 확인한다.
- 스크롤·휠·클릭은 실제 표시한 영역과 원본 identity를 따른다. 읽기 화면 위의 휠이 뒤 목록을
  바꾸지 않게 하고, 화면을 다시 그리기 전 위치 표로 다른 항목을 선택하지 않는다.

Memory 편입, 프리셋 이름 변경, Task Review 통합, Fusion·Schedules 이동,
복사 키·숫자 바로가기 변경, 월 단위 추이는 아직 이 문서의 제안이다.

## 사용량에서 답할 질문

[#49175](https://github.com/jeong-sik/masc/issues/49175)의 질문은 토큰, 비용,
Keeper별 사용, 도구 실패율, p95 지연, 추세다.

| 질문 | 소스와 범위 |
|---|---|
| 토큰·비용·Keeper별 사용 | Usage의 Keepers와 Keeper 비용 조회. 보고된 기간·통화·미보고 범위를 보존한다. |
| 도구 호출·실패·p95 추이 | `GET /api/v1/tool-metrics/series`와 Usage의 Calls. 호출이 없는 칸의 p95를 0으로 채우지 않는다. |
| 제공자 쿼터 추이 | Usage의 Trend. 쿼터 비율은 토큰 수나 비용이 아니다. |
| 토큰·비용의 시간별 추세 | 별도 제안이다. `usage/series`를 이미 존재하는 API로 취급하지 않는다. |

호출·실패는 합계, p95는 해당 집계 칸의 분포, 쿼터는 보고한 창의 값이다.
보고가 없는 기간은 비워 두며 초기화 시각 경과를 회복으로 해석하지 않는다.
표시용 수치를 Keeper의 행동 제한으로 사용하지 않는다.

정본: [HTTP 요청](../../bin/masc_tui_http.ml),
[Calls](../../bin/masc_tui_usage_calls.ml), [사용량 타입](../../lib/tui_decode_usage.mli).

## 검증

실제 사용 흐름을 확인한다. 같은 Keeper의 대화에서 호출·원본·Task 근거로 이동하고,
Esc로 돌아오며, 지연·실패·권한 상실 후에도 초안과 출처를 보존하는지 확인한다.
한국어·긴 경로·색상 없는 터미널·좁은 화면에서 선택과 원문을 읽을 수 있어야 한다.

보낸 요청·저장한 상태·결정을 검사한다. 문구·행 순서·스크린샷·호출 개수나 특정 함수 사용을
테스트 계약으로 고정하지 않는다. 소스 리뷰·타입 검사·실행·화면 관측·설치는 각각의 증거로
기록하며, 실행하지 않은 단계는 미검증으로 남긴다. 빌드와 CI 실행은 제품 계약을 따른다.
