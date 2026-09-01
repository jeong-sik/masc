---
rfc: "tui-operator-ia"
title: "TUI 정보 구조 재설계 — 18탭을 운영자 질문 6개로 접고, Keeper 워크벤치를 중심 화면으로"
status: Draft
created: 2026-09-01
updated: 2026-09-01
author: claude
supersedes: []
superseded_by: null
related: ["#32098", "#31867", "#31464", "task-1203", "docs/design/tui/TUI-ROADMAP.md"]
---

# RFC: TUI operator IA (tui-operator-ia)

## 0. Summary

TUI 는 2기 캠페인(TUI-ROADMAP)으로 대시보드의 모든 section 을 터미널로 옮기는 데
성공했다. 그 대가로 **최상위 탭 18개**가 남았다. 운영자(2026-09-01)가 실제 화면
18장을 놓고 판정한 결론은 두 가지다:

1. **위계가 없다.** 탭 18개가 같은 급으로 나열되고, Tab 순환과 팔레트(`:`)가
   유일한 이동 수단이다 (#31867). 화면끼리 데이터가 겹치고(Lanes ↔ Runtime,
   Repos ↔ Code, Acting ↔ Logs), 2행짜리 화면(Repos, Connectors)이 Board·Planning
   과 같은 무게를 갖는다.
2. **핵심 데이터가 숨어 있다.** 운영자가 물은 것 — "Skill/Tool 트리거 구분",
   "async 도구 대기 현황", "diff 는 어디서", "memory 카테고리", "다음 턴 컨텍스트
   주입과 용량" — 은 **전부 이미 구현돼 있다.** 컨텍스트 인스펙터는 `/context`
   슬래시 명령 뒤에(masc_tui.ml:5189), diff 는 세 화면에 쪼개져(채팅 Ctrl-D full ·
   Changes · Repos `d`), tool kind(Skill/Keeper/Fusion)는 펼친 fold 안에만,
   async 큐는 Tools 의 다섯 pane 중 하나에 있다. 데이터의 문제가 아니라 IA 의
   문제다.

이 RFC 는 (A) 최상위 탭을 운영자 질문 단위 6~8개로 접는 구조와,
(B) Keeper 상세를 채팅·호출·diff·컨텍스트·메모리를 한 곳에서 여는
**워크벤치**로 승격하는 설계, (C) 거기까지 가는 PR 절단선을 정한다.

Verification·Harness 가 Planning 의 서브탭으로 흡수된 선례
(bin/masc_tui_types.ml:1185, docs/TUI-GUIDE.md:690)가 이 방향이 이미 코드에
있음을 보여준다. 이 RFC 는 그 패턴을 끝까지 적용한다.

## 1. 현재 인벤토리 (2026-09-01 실측, v0.28.0 f4fa884)

최상위 탭 18개. 괄호는 운영자가 그 화면에서 실제로 답을 얻는 질문.

| # | 탭 | 내용 | 판정 |
|---|---|---|---|
| 1 | Overview | 헬스 스트립 + Attention + TUI 세션 이벤트 + Task 목록 수십 행 | 유지하되 다이어트 — Task 목록은 Planning 소관 |
| 2 | Acting | 전 Keeper 턴/호출 실시간 피드 | 유지 — 단 `composite` 노이즈가 turns scope 를 침범 중 (결함) |
| 3 | Keepers | 함대 표 + 상세/채팅/로그/호출 | **워크벤치로 승격** (§3) |
| 4 | Memory | Keeper별 스냅샷 건강 통계 | 사실 브라우저가 아님 — 워크벤치 pane + 함대 롤업으로 재편 |
| 5 | Lanes | standalone 서비스 레인 관측 | Runtime 서브탭으로 흡수 |
| 6 | Approvals | 승인 대기 + 질문 대기 | **Inbox 로 확장** — Attention·외부 멘션 합류 |
| 7 | Board | Keeper 게시판 | 유지 |
| 8 | Planning | Goals / Task Review / Evaluator Verdicts | 유지 (이미 허브) — Schedules·Fusion 서브탭 후보 |
| 9 | Schedules | wake 스케줄 목록 | Planning 또는 Keeper 워크벤치로 흡수 |
| 10 | Fusion | fusion 런 목록 | Planning "판정" 축으로 흡수 |
| 11 | Repos | 등록 저장소 2행 | Code 와 병합 → Workspace |
| 12 | Code | base path 파일 브라우저 | Repos 와 병합 → Workspace |
| 13 | Connectors | 채널 4행 + bind/unbind | Config 또는 System 서브탭으로 흡수 |
| 14 | Runtime | 레인/슬롯/프로브 | 유지 — Lanes 흡수의 수용처 |
| 15 | Config | runtime.toml/models/params/prompts/themes | 유지 (이미 허브) |
| 16 | Resources | MCP 리소스 98개 목록 | Tools 와 병합 (도구/리소스 카탈로그) |
| 17 | Tools | Keeper surface / async runs / receipts / usage / catalog | 유지 (이미 허브) — per-Keeper pane 은 워크벤치와 연결 |
| 18 | Logs | 시스템 로그 | Acting 과 한 지붕(Activity) 검토 |

숨은 화면: Changes(Keepers 선택을 따라가는 24h 기록), Keeper calls(`t`),
컨텍스트 인스펙터(`/context` 오버레이), Board hearth/comment/score 서브뷰.

## 2. 문제 정의 — 운영자 질문과 현재 응답 위치

이 제품의 성공 조건(연속 턴, 기억 연속성, Keeper 간 통신, 출력 목적지 판단)을
운영자가 **화면에서 검증할 수 있는가**가 TUI 의 존재 이유다. 현재 응답 위치:

| 운영자 질문 | 데이터 | 현재 위치 | 문제 |
|---|---|---|---|
| 지금 무슨 결정을 기다리나 | approvals + questions + attention | Approvals, Overview, footer 곳곳 | 세 곳 분산, 합산 배지 없음 |
| 이 Keeper 가 방금 뭘 했고 왜 | 턴 trace, tool rows | 채팅(compact fold) | compact 행이 kind 를 익명화 ("Ran 2 tools") |
| Skill 이 트리거됐나, Tool 인가 | typed kind (Skill/Keeper/Fusion) | 펼친 fold 안에만 | 접힌 상태에서 구분 불가 |
| async 도구 뭐가 돌고 뭘 대기 | 합성 브로커 큐 | Tools > async runs | 채팅/워크벤치와 단절 |
| diff 는 어디서 보나 | file-change artifacts, git diff | 채팅 Ctrl-D full · Changes · Repos `d` | 세 렌즈 분산, 발견성 낮음 |
| 다음 턴에 뭘 알고 시작하나, 용량은 | Turn_record 바이트 구성 + prompt capture | `/context` 오버레이 | 발견 불가에 가까움. "마지막 턴" 뷰만 존재 |
| memory 에 뭐가 쌓였나, 카테고리는 | ordinary/source-bound facts | Memory 탭(통계만) | 사실 내용·카테고리 브라우저 부재 |
| 작업의 결과와 이유 | verdicts, evidence | Planning 3-pane, Board verification | Task→턴→diff→verdict 를 잇는 길이 없음 |

## 3. 설계

### 3.1 최상위: 운영자 질문 6개 + 상세 위계

(경쟁 TUI 조사와 코드 매핑 결과 반영해 확정 — §5, §6)

### 3.2 Keeper 워크벤치

### 3.3 삭제/흡수 목록과 하드컷 원칙

레거시 별칭·리다이렉트·"이 탭은 이사갔습니다" 안내를 남기지 않는다. 탭 변수와
뷰 variant 를 지우고, PTY 스위트·가이드·팔레트 사전을 같은 PR 에서 갱신한다.

## 4. PR 절단선

## 5. 경쟁 TUI 조사 (2026-09-01)

## 6. 코드 매핑 근거

## 7. 하지 않는 것

- 렌더 기반 교체(ANSI 직접 → Notty 등)는 이 RFC 밖. ROADMAP 의 "화면이 다
  붙은 뒤 측정으로 결정" 조항을 따르되, 이 RFC 의 뷰 통폐합이 그 측정의
  전제 조건을 바꾸므로 통폐합 후 재측정한다.
- #32098 의 화면별 7단계 실측은 살아남는 화면에 그대로 적용된다. 이 RFC 는
  어떤 화면이 살아남는지를 정한다.
