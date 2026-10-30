---
rfc: "webmcp-capability-lanes"
title: "WebMCP 를 masc 능력으로 — credential 위임(C), 생태계 센서(D), 공유 화면·사람 승인(E)"
status: Draft
created: 2026-08-29
updated: 2026-08-29
author: claude
supersedes: []
superseded_by: null
related: ["webmcp-dashboard-agent-surface", "webmcp-keeper-consumption"]
---

# RFC: WebMCP Capability Lanes (webmcp-capability-lanes)

## 0. Summary

WebMCP 소비 통로(RFC-webmcp-keeper-consumption)는 이미 있다. 이 RFC 는 그 통로를
실제로 값이 나오게 쓰는 세 갈래를 설계하고, 각 갈래의 **게이트를 명시**한다. 게이트가
이 문서의 핵심이다 — 통로 자체보다 "어디까지 지금 열고 어디부터 사람이 봐야 하는가"가
값과 위험을 가른다.

| Lane | 무엇 | 지금 상태 | 게이트 |
|---|---|---|---|
| **C. Credential 위임** | 로그인된 브라우저 페이지에 도구를 심어, keeper 가 토큰 없이 인증된 행동을 함 | 프레임워크 + read-only 예제 (실험) | 인증된 mutating 은 대상 목록 + read-only 우선 검증 뒤 |
| **D. 생태계 센서** | 외부 사이트가 WebMCP 를 켜는 순간을 감지 | **구현됨** (`webmcp-bridge.mjs detect`) | 없음 — 관측만 함 |
| **E. 공유 화면·사람 승인** | 한 페이지가 사람에겐 UI, keeper 에겐 도구 표면. 사람이 mutating 도구를 arm | 프로토타입 + 배선 설계 | 라이브 대시보드 mutating 노출은 arming UX 리뷰 뒤 |

Lane 2(앱 QA 도구)는 사용자 지시로 이 묶음 뒤 별도 진행.

## 1. Lane D — 생태계 센서 (구현됨)

`dashboard/scripts/webmcp-bridge.mjs detect` 가 열린 모든 탭을 훑어 어느 origin 이
`document.modelContext` 도구를 노출하는지 보고한다. `--expect-external` 은 localhost
밖 origin 이 surface 를 낼 때만 exit 0 — 그 전에는 exit 4 로 침묵한다.

용도: RFC-webmcp-keeper-consumption §5 의 승격 트리거 1·2("발표 참여사 실배포",
"Gemini/Claude-in-Chrome 소비 개시")를 사람이 매번 확인하지 않아도 되게 한다. 후보
사이트(Expedia, Shopify, Target, …)를 연 브라우저에 대고 스케줄로 돌리면, 그 사이트가
WebMCP 를 켜는 날 신호가 온다.

검증(2026-08-29, Chrome 151): 2탭 스캔 → surface 1(spike echo-add), external 0,
`--expect-external` exit 4. 게이트 없음 — 관측만 하고 아무 행동도 하지 않는다.

## 2. Lane C — Credential 위임 tool host

### 2.1 아이디어

운영자 브라우저에는 이미 로그인 세션이 있다. userscript(Tampermonkey) 나 확장으로 그
페이지에 `registerTool` 을 심으면, 도구의 구현은 **페이지 자신의 fetch + 세션 쿠키**다.
keeper 가 `keeper_webmcp_call` 로 그 도구를 부르면 인증된 행동을 하는데, **토큰이 masc
store 에 저장되지 않는다.** 자격증명이 브라우저 밖으로 나가지 않는 위임.

### 2.2 냉정한 절삭 (왜 이게 전부 값은 아닌가)

JIRA / Slack / GraphQL 은 이미 `sb` CLI 에 토큰이 있어 이 방식과 중복이다. Lane C 가
이기는 자리는 **API 토큰이 없거나 만들 수 없는 곳뿐**이다:

- 사내 admin/운영 페이지 (API 미제공)
- 2FA·SSO 세션에 묶여 프로그래밍 토큰을 못 만드는 서비스
- 공개 API 가 없는 서드파티 대시보드

→ **선행 작업: 그런 대상이 실제로 몇 개인지 목록화.** 목록이 비면 Lane C 는 만들 이유가
없다. 이 목록은 사용자만 안다(사내 페이지 구성). 프레임워크는 목록과 무관하게 패턴으로
증명해 두되, 대상 없는 채로 main 에 상주시키지 않는다 — Lane D 의 "대상 없는 총" 경고와
같은 논리.

### 2.3 게이트 — read-only 우선

`keeper_webmcp_call` 은 이미 non-readonly + `Effect_outcome_unknown` 이다(페이지가
어떤 도구를 등록했는지 브리지가 모르므로). Lane C 페이지 도구를 심을 때:

1. **1단계는 read-only 도구만** (조회/검색). 인증된 write 는 심지 않는다.
2. `registerTool` 의 `exposedTo` 로 노출 origin 을 제한한다(기본 same-origin).
3. mutating 을 열기 전, masc Gate 가 `keeper_webmcp_call` 을 외부 효과로 다루는지
   확인한다(Lane E 의 arming 과 같은 승인 경로를 태운다).

프레임워크(`registerMascReadTool`)는 read-only 만 등록하도록 이름과 시그니처로 강제한다.

## 3. Lane E — 공유 화면과 사람 승인

### 3.1 아이디어

한 페이지가 두 소비자를 가진다: 사람은 UI 로 보고, keeper 는 도구 표면으로 부른다.
WebMCP 스펙이 명시한 human-in-the-loop 그 자체다. masc 에서 가장 자연스러운 형태:

- keeper 가 도구 호출로 findings/제안을 화면에 밀어넣고,
- 사람이 화면에서 누른 결정이 keeper 가 다음 턴에 읽는 데이터가 된다.

### 3.2 미뤄둔 mutating 노출의 답

RFC-webmcp-dashboard-agent-surface 는 read-only 8종만 노출하고 mutating 은
"승인 UX 설계 전까지 보류"로 남겼다. Lane E 가 그 UX 다: **사람이 버튼으로 mutating
도구를 N분간 arm** 하고, arm 된 동안에만 `installWebmcpAgentSurface` 가 그 도구를
`registerTool` 한다. arm 이 풀리면 도구가 표면에서 사라진다.

배선(설계, 라이브 반영은 게이트 뒤):

- 대시보드에 arming 컨트롤(사람이 명시적으로 누름, 기본 off, 타이머로 자동 해제).
- arm 상태를 `webmcpModelContext` 설치 로직이 읽어, arm 된 mutating 도구만 추가 등록.
- mutating 도구의 `execute` 는 read-only 와 달리 결과에 "누가 arm 했는지 + 언제
  만료"를 실어, keeper 가 만료된 arm 에 기대지 않게 한다.
- arm 은 브라우저 로컬 상태다. 서버 authority 가 아니다(파생 상태 게이트 금지 원칙).

### 3.3 게이트

라이브 대시보드에 mutating 도구를 실제로 여는 것은 arming UX 리뷰 통과 뒤다. 이
RFC 와 함께 나가는 것은 arming UX **프로토타입**(독립 HTML)과 위 배선 설계뿐이다.
provider 코드(`dashboard/src/api/webmcp.ts`)는 이 PR 에서 바꾸지 않는다.

## 4. 비목표

- Lane C 의 credential write 를 게이트 없이 여는 것.
- Lane E 의 arm 상태를 서버 store 에 authority 로 저장하는 것.
- 외부 사이트 소비 lane 구현(Lane D 는 감지만, 소비는 RFC-webmcp-keeper-consumption
  §5 트리거 뒤).

## 5. 이 PR 에 실제로 들어가는 것

- Lane D: `detect` 서브커맨드 (구현·검증 완료).
- Lane C: `dashboard/userscripts/masc-webmcp-tools.user.js` — `registerMascReadTool`
  헬퍼 + read-only 예제. 실험 표식. 대상 목록은 사용자 입력 대기.
- Lane E: arming UX 프로토타입(독립 HTML) + 본 문서 §3 배선 설계. 라이브 provider 무변경.
