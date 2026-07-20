---
rfc: 0351
title: Memory-first context management and compaction sunset
status: Draft
created: 2026-07-20
authors: [yousleepwhen, claude]
issues: [25461, 25462, 25463]
relates: [RFC-0000 Goal 3, RFC-0233, RFC-0244, RFC-0247, RFC-0259, RFC-0332]
implementation_prs: []
evidence: knowledge/research/2026-07-20-memory-first-context-management-adversarial-design.md, knowledge/research/2026-07-20-memory-first-context-experiment-log.md (~/me worktree feature/memory-first-context-design)
---

# RFC-0351 — Memory-first context management and compaction sunset

## 0. 한 줄 요약

컨텍스트 관리의 주력을 "쌓인 transcript를 넘칠 때 요약-재작성(compaction)"에서 "타입 수명 + 상시 메모리(Write/Judge) + 검색 주입(Select) + 매턴 조립 예산"으로 옮기고, 컴팩션 이벤트는 동결(freeze) → 도달 불능 → 통삭제(sunset)한다. 축소 시점에 LLM이 판단할 것이 남지 않게 만드는 것이 목표다.

## 1. 배경 — 라이브 실증 (2026-07-20)

| 실측 | 값 | 함의 |
|---|---|---|
| rondo 매턴 input | 677k tokens, I/O비 1,921:1 | transcript 2.79MB 중 **thinking 47.4% + tool_result 23.3% = 타입 수명이 끝난 죽은 무게 70%+** |
| analyst exact-dup | transcript의 25.7% (wake-marker ×359, world-state frame ×51, 동일 보고 ×72/60/51/39/36) | 반복 유입이 구조적 (#25462) |
| analyst dedup purge 효과 | 결정론 규칙만으로 input **325,712 → 241,117 (−26.0%)**, fill 124%→92% (E2/E3) | 최대 레버는 Memory OS가 건드리지 않는 transcript 층에 있음 |
| 컴팩션 자격 맹점 | `text_blocks`가 Thinking/ToolUse/ToolResult 포함 메시지를 배제 → LLM plan "성공" 시 saved **920B (0.07%)** | 현행 컴팩션은 구조적으로 무력 |
| 컴팩션 커밋 버그 | persist 게이트가 파이프라인 자신의 산출물을 `Invalid_structural_source`로 거부, durable retry가 08:16Z부터 무한 재발화 (breaker 부재) | #25461, analyst 평생 compaction_count=0/2,802턴 |
| 참조 시스템 | claude-code SM-compact(메모리가 요약 대체) · hermes on_pre_compress · openclaw pre-compaction memory flush; **structured-plan reducer 사용처 0곳** | 방향 검증: 메모리가 선취, reducer는 강등 |

적대적 판정(Judge 3렌즈, 2026-07-20): "컴팩션=메모리=같은 관심사(context management)"는 검증, "즉시 전면 제거"는 반증. 지지되는 경로는 **선(先)유입차단·후(後)사장(死藏)**이다.

## 2. 원칙

1. **판단은 LLM 경계, 정밀함은 결정론 층.** 축소 시점의 "무엇이 중요한가" 판단을 제거한다 — 중요한 것은 librarian/consolidation이 상시로 이미 추출했고, 나머지의 수명은 타입이 결정한다.
2. **결정론 층에 남는 것은 판단이 아니다**: (a) 타입 수명(thinking=턴 스코프, tool_result=사이클 스코프), (b) 예산 산술(정수 비교), (c) 프로토콜 경계(tool_use/tool_result 쌍, provider replay 계약). 어디에도 중요도 점수·문자열 분류·휴리스틱 임계값이 없다.
3. **어떤 단일 계층도 유일한 context manager가 되지 않는다.** fleet-freeze의 교훈은 "overflow 시점에 모든 축소 리스크가 몰린 단일 LLM 서브콜"이었다.
4. **죽일 대상에 투자하지 않는다.** 컴팩션 파이프라인은 수리 최소화(무한루프 종결 등 안전만) 후 동결한다. 결정론적 floor(#25281 계열)도 신규 투자하지 않는다 — assembly가 floor를 대체한다.
5. **경계 유지**: OAS는 MASC를 모른다. 필요한 OAS 표면(typed overflow, replay 계약, caller-assembled messages)은 이미 존재하며, provider별 replay 정책 교정은 capability 데이터 정정이다.

## 3. 목표 아키텍처 (5층 ordering)

```
L1 Write   librarian 상시 추출 + delivery accounting (drop-not-block → due-backlog)
L2 Judge   consolidation = LLM-judged merge/forget (중복 병합의 유일 결정자, RFC-0332 준수)
L3 Select  검색 기반 recall 주입 (bulk 500/500 전량 주입 은퇴; RFC-0244 계열/pgvector)
L4 Flush   예산 근접 시 memory flush silent turn (openclaw shape) — 떨어져 나갈 내용의 durable 저장 유도
L5 Budget  매턴 조립 예산: persona + dynamic + Select 결과 + 최근 창(구조 경계 존중) ≤ budget
           초과 시 결정론적 축소 순서(Select 주입분 → 오래된 최근 창)로 재조립. history 재작성 없음.
```

- L5의 "최근 창"은 recency 구조이지 중요도 판단이 아니다. keeper는 일직선 타임라인이므로 최근성은 타임라인의 구조 자체다. 의미 보존은 L1-L4가 이미 수행했다.
- typed provider overflow(`Error.Api (ContextOverflow _)`)는 여전히 도착할 수 있다(GLM/Kimi/DeepSeek 토큰 카운팅 typed-Unsupported → 예산은 직전 턴 api_usage 반응형). 대응은 **더 작은 재조립**(결정론적 degrade)이지 checkpoint 수술이 아니다.

## 4. 타입 수명 (Typed Content Lifecycle)

| 타입 | 수명 | 근거 |
|---|---|---|
| assistant thinking | **턴 스코프** — 진행 중 tool 루프 안에서만 유지 (provider replay 계약 준수: OAS `reasoning_dialect.replay_policy`) | reasoning 모델 일반 계약("reasoning을 다음 턴에 되돌려 보내지 마라"); rondo 47.4% 실측 |
| tool_result | **사이클 스코프** — 닫힌 사이클은 조립 시 축약/스필 대상 (Anthropic "microcompact/tool-result clearing = safest touch") | rondo 23.3% |
| assistant/user text | 의미 콘텐츠 — L1/L2가 memory로 추출, 최근 창 밖에서는 조립에서 제외 | |
| wake marker 등 무정보 자극 | **비영속** — §5 | analyst ×359 |

Provider별 replay 정책이 `Preserve_always`로 선언된 모델(예: mimo 계열)은 공식 문서 재검증 후 turn-스코프 정책으로 교정한다(OAS capability 데이터 정정, 별도 검증 진행 중). 문서가 실제로 cross-turn replay를 요구하면 예외로 존중한다.

## 5. Persistence 정책 — 무정보 턴은 영구 transcript를 만들지 않는다 (#25462)

- `autonomous_wake_marker` 상수를 매 wake마다 새 user 메시지로 영속하는 현행 동작을 중단한다 (#25193 수리의 잔여 누수).
- **typed 신호 기반 규칙**: tool 사이클 0 + 가시 전달(board/chat/connector) 0 + task/goal transition 0인 autonomous 턴은 checkpoint transcript에 기록하지 않는다. 관측은 turn_record/receipt(RFC-0233)가 이미 담당한다.
- 문자열 검사·내용 판단 없음 — 실행 receipt의 typed 필드만 사용.

## 6. Sunset 단계

| 단계 | 내용 | 게이트 (experiment-log 지표) |
|---|---|---|
| S0 | 안전 수리만: #25461 무한 retry의 typed terminal settlement(연속 실패 시 재시도 중단 + Board/attention 표면화), 구조 거부 근본원인 수정. 파이프라인 기능 투자 동결 | 재시도 폭풍 0건/24h |
| S1 | #25462 persistence 정책 + provider replay 교정(문서 검증분) + 플릿 1회 청소(결정론 dedup purge, 백업 필수) | 대상 keeper input −25%+ (E3 재현), wake-marker 신규 유입 0 |
| S2 | L1/L2 건강화(consolidation fail-loud, valid_until, delivery accounting) + L3 Select + L4 Flush | recall 주입 bytes −80%+, dup family 감소 추세, RFC-0247 P-1 eval 통과 |
| S3 | L5 조립 예산 배선 — transcript는 조립의 입력 소스 중 하나로 강등 | typed overflow 발생률 ~0, 조립 재시도로 전량 흡수 |
| S4 | 컴팩션 이벤트 통삭제: trigger/summarizer/policy/audit/dashboard 표면 + event-queue variants. exhaustive match 전수 재작성(catch-all `_ ->` 금지). RFC-0000 Goal 3/48h DoD 개정 동반 | 삭제 후 48h 라이브 무사고, `Manual_compaction_requested` 잔존 참조 0 |

S4 전까지 typed trigger(`Provider_overflow | Manual`)와 partition/evidence/CAS 불변식은 유지한다(전환기 보험). S4에서 함께 제거하되, tool-사이클 경계 검증 로직은 L5 조립기의 불변식으로 이관한다.

## 7. 거버넌스 관계

- **RFC-0000 Goal 3**: 트리거("WHEN")는 이미 준수 상태이므로 유지; reducer("HOW")와 48h DoD의 컴팩션 관측 요구는 S4에서 본 RFC 기준으로 개정한다. keep-recent-N 금지 조항은 "중요도 판단으로서의 keep-recent" 금지로 해석을 명확화한다 — L5의 최근 창은 타임라인 구조이며 별도 판단 메커니즘이 아니다.
- **RFC-0332**: 유지·강화. 중복 병합은 write-side lexical filter가 아니라 L2 consolidation(LLM-judged)만. transcript의 exact-dup(자체 상수·byte 동일)는 메모리 병합과 무관한 별개 범주다.
- **RFC-0247 P-1**: S2 진입 전 memory-quality eval harness 필수 (Harness First).
- **RFC-0233**: turn_record가 실험 하네스의 SSOT. 후속으로 transcript 분해(`ctx_composition` 세그먼트)의 turn_record 편입을 검토한다(관측 갭 G1).

## 8. Non-goals

- LLM bulk-summarize의 개선/재작성 (동결 대상에 투자 금지)
- 결정론적 floor(#25281)의 신규 완성 (assembly가 대체; 열린 PR 처분은 S3 시점 재평가)
- write-side jaccard/문자열 dedup (RFC-0332 기각 유지)
- OAS에 MASC 개념 유입 (replay 교정은 provider capability 데이터 정정일 뿐)

## 9. 리스크

| 리스크 | 대응 |
|---|---|
| S2 완성 전 overflow 발생 | 전환기 동안 기존 파이프라인 동결 유지(S0 안전 수리 포함) + 운영 청소 절차(백업 포함) 문서화 |
| 무정보 턴 판정 오탐(실제 의미 있는 턴 미영속) | typed 신호 3종(tool/visible/transition) 전부 0일 때만; counterfactual 테스트로 각 신호 단독 세트 시 영속 확인 |
| replay 교정이 provider 계약 위반 | 모델별 공식 문서 Evidence Record 없이는 교정하지 않음 |
| provider 무카운팅 모델의 예산 산술 오차 | 반응형(직전 api_usage) + typed overflow 시 결정론 degrade 재조립 |
