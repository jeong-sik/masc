---
rfc: "keeper-memory-consolidation"
title: "Keeper durable memory consolidation — deprecate memory_bank into Memory OS"
status: Draft
created: 2026-06-24
updated: 2026-06-24
author: vincent (drafted by Claude Opus 4.8)
supersedes: []
superseded_by: null
related: ["0239", "0257", "0243", "0259", "0285"]
implementation_prs: []
---

# RFC: Keeper durable memory consolidation — deprecate memory_bank into Memory OS

Status: Draft · slug-only (README §정책: 번호 발급 폐지) · 2026-06-24

## §1 Problem — keeper durable memory가 두 시스템으로 공존하며 둘 다 샌다

`<base-path>/.masc` (live runtime) keeper들의 "가짜/나쁜 기억" 보고에서 출발한 전수 진단 결과, keeper의
durable 기억이 **두 개의 독립 시스템**으로 공존하며 **둘 다 bound 없이 자란다**.

| 시스템 | 코드 | 저장 | 상태 (2026-06-24 측정) |
|---|---|---|---|
| **memory_bank** | `lib/keeper/keeper_memory_bank.ml` | `<masc_root>/keepers/<name>.memory.jsonl` | anti-thrash 가드 **전무**. 10 keeper × 60줄 = 600줄이 near-dup·idle-echo·운영대기 박제로 오염 |
| **Memory OS** | `lib/keeper/keeper_memory_os_*.ml` | `<masc_root>/config/keepers/<name>.facts.jsonl` + `episodes/` | RFC-0239 retention(`cap_facts` 256) "Implemented" 기재. 그러나 facts가 executor 349·mad-improver 348·idealist 337줄 → **256 cap 실작동 안 함** |

### 1.1 memory_bank 오염의 근본 원인 (file:line, 적대 검증됨)

1. **near-dup 무한 append**: explicit memory/tool-result writer가 동일 사실을 반복 저장할 수 있다.
   내용 dedup은 compaction(caller `keeper_agent_run_post_turn_memory.ml:183`
   → `lib/memory.ml:147`) 내부에만 있고, 게이트(`keeper_memory_policy.ml` target_notes 하한 40 /
   trigger 60KB)를 관측 파일(60줄·24–49KB)이 못 넘어 **compaction이 한 번도 실행된 적 없음**.
2. **dedup이 정확일치라 무력**: compaction의 `dedup_by_key memory_row_key`
   (`keeper_memory_bank_selection.ml:87`)는 StringSet 정확일치. `normalize_memory_text_key`(:135)는
   구두점·공백·대소문자만 정규화 → 커밋해시(`f1f342d2c`)·post-id·표현 변주가 든 near-dup은 서로 다른
   키 → 미수렴. semantic dedup(jaccard 0.85 `dedup_memory_candidates` selection:104)은 **존재하나
   write-side candidate gating 전용이고 compaction 경로에 미배선**.
3. **이중 주입 (측정상 중복 아닌 보완 — 가설 정정)**: durable 기억이 두 경로로 동시 프롬프트
   주입된다 — bank "Long-term memory:" 블록(`keeper_turn.ml:570`, long_term top-3) + Memory OS
   facts(`keeper_run_tools_hooks.ml:359`, `render_if_enabled`, default-ON). 매 턴 둘 다 write
   (`post_turn_memory.ml:37`). **단 Stage 1 측정(§5.1)이 초기 "double-coverage(중복 주입)" 가설을
   반증**: 두 경로는 토큰 0 중복 = 중복이 아니라 *다른 종류*(bank=`[consolidated:N]` progress 서사,
   facts=명제형 claim)다. bank LT top-3 내용은 idle-echo("Acknowledged loop", "idle state confirmed")
   ·잡담이라 제거가 정당하나, "facts가 같은 정보를 커버하니 안전"이라는 단순 논리는 성립하지 않는다.
   bank LT는 *대체*가 아니라 *low-value 서사 제거*로 정당화된다.
4. **continuity는 bank 비의존**: keeper runtime 복구는 `.memory.jsonl`이 아니라 OAS
   checkpoint/context와 typed MASC metadata에서
   온다. → **bank를 꺼도 keeper continuity는 안 깨진다** (통합 리스크를 크게 낮추는 핵심 사실).

### 1.2 horizon/priority 변별 붕괴 (부차 증상, 통합으로 자연 소멸)

- horizon은 내용이 아니라 `kind` 문자열 고정 매핑(`keeper_memory_policy.ml:205-210`): "operator gate
  해제 대기"가 `constraints`면 무조건 mid_term. 분류 오류가 아니라 설계상 고정.
- priority = kind floor(`:858-866`, constraints 90) + signal_bonus(`:875-897`, `release`/`must`/`필수`/
  `차단`이 운영 텍스트에 편재) → constraints 90+8=98, decision 86+8=94로 박제. 망각·정렬 신호로 못 쓴다.

이 두 증상은 memory_bank 고유의 ad-hoc 분류 체계에서 오며, Memory OS의 confidence/recency 스코어로
durable 기억을 단일화하면 **소멸한다** (별도 수정 불필요).

## §2 Goal

keeper durable 기억을 **Memory OS 단일 경로로 통합**하고 memory_bank를 deprecate한다. 단 통합
타겟인 Memory OS retention(`cap_facts`)이 실제로 작동해야 의미가 있으므로, retention 실작동 보장을
본 에픽 범위에 포함한다 (§3 Stage 3).

비목표: Memory OS 스코어 모델 재설계(RFC-0243/0259/0285 소관)는 본 RFC 범위 밖. 본 RFC는 *두 시스템
공존 제거*와 *retention 실작동*에 한정한다.

## §3 Plan — 4-stage deprecate (각 독립 PR + 롤백)

masc는 RFC 필수 영역 + 워크어라운드 게이트 적용. 각 stage는 독립 PR, 롤백 경로 필수.

- **Stage 1 (측정 + flag)**: keeper 프롬프트의 bank long-term top-3 vs Memory OS facts recall
  **중복도/고유도**를 정량화하는 offline harness(read-only, 결정론). + bank long-term inject
  (`keeper_turn.ml` durable_text 가드)를 env flag `MASC_KEEPER_BANK_LONGTERM_INJECT`(default=ON)
  뒤로. 키는 `Keeper_memory_bank_env.bank_longterm_inject_enabled` named consumer 한 곳에 정의(SSOT)
  하여 가드·테스트가 공유. off 시 Memory OS facts 단독. **가설을 측정으로 검증** (Harness First).
- **Stage 2 (read 재포인팅)**: dashboard/status의 `memory_bank` JSON 표면 4곳(`keeper_status.ml`,
  `keeper_status_detail.ml`, `dashboard_http_keeper_feeds.ml`,
  `server_dashboard_http_memory_subsystems.ml`)을 Memory OS facts로 재포인팅. 표면별 독립 PR.
  **가장 광범위한 리스크 표면**.
- **Stage 3 (write 중단 + retention 실작동)**: explicit memory/tool-result bank write를 중단하고
  tool-result notes는 Memory OS facts
  producer로 이주. continuity는 snapshot cache 유지. **동시에 `cap_facts`가 실제로 호출되도록 배선**
  (현재 349줄까지 자라는 미작동을 닫음).
- **Stage 4 (제거)**: `keeper_memory_bank*` 모듈 + `.memory.jsonl` 경로(`keeper_types_support.ml:84`)
  + compaction + 관련 테스트 제거. orphan gc(`workspace_gc.ml:377`) 정리.

## §4 Anti-workaround 선언

본 에픽에서 **다음은 워크어라운드로 거부**한다 (CLAUDE.md 워크어라운드 거부 기준):

- compaction `target_notes`/`trigger_bytes` 임계를 낮춰 "더 자주 돌게" 하는 cap 튜닝 — symptom 억제.
  근본은 두 시스템 공존 제거 + write-side semantic dedup. 임계 조정은 dedup이 정확일치라 어차피 무력.
- bank near-dup을 외부 스크립트로 휴리스틱 청소(jaccard/키워드) — 비결정·재발. (데이터 1회 truncate는
  완료했고 백업 보존했으나, 이는 *청소*이지 *수정*이 아님.)

## §5 Verification

### §5.1 Stage 1 측정 결과 (2026-06-24, 백업 bank vs live facts)

read-only harness로 bank long-term top-3(프롬프트 주입분, recency desc·limit 3)와 Memory OS
facts(`claim`)를 jaccard≥0.5로 대조:

| | 값 | 해석 |
|---|---|---|
| bank LT top-3 ∩ facts | **0 / 30** | 토큰 수준 0 중복 → 두 경로는 *보완*(서사 vs 명제)이지 중복 아님 |
| bank-only top-3 | 30 (전부) | 끄면 빠지는 것 = `[consolidated:N]` idle-echo·잡담 junk (예: "Acknowledged loop", "방호복 입은 애들 M.E.G.") |
| facts cap(256) 초과 | **+237줄** (executor +96, idealist +81, verifier +23) | RFC-0239 retention 미작동 데이터 확증 → Stage 3에서 닫음 |

**결론**: Stage 1 flag off의 정당화는 "중복 제거"가 아니라 **"low-value consolidated 서사 inject
제거"**. facts가 bank LT를 대체하지 않으므로, 두 시스템 통합은 단순 deprecate가 아니라 *bank가 주던
서사 정보 중 보존 가치 있는 것*을 식별하는 과정이 선행돼야 한다 (측정상 현재 bank LT top-3는 보존
가치 0). harness: 일회성 가설검증 스크립트(read-only).

### §5.2 Stage 1 회귀 테스트 (구현됨)

- **kill-switch 계약 단위 테스트**: `test/test_keeper_bank_longterm_inject_flag.ml`. 키 SSOT를
  `Keeper_memory_bank_env.bank_longterm_inject_enabled`(named consumer, 기존 `memory_llm_summary_enabled`
  관습) 한 곳으로 모으고, keeper_turn 가드와 테스트가 같은 함수를 호출한다. pin: unset→default ON
  (Stage 1 무동작변화 약속), off/on 토큰 집합, invalid→default ON fallback. **non-vacuity 증명**:
  default `true`→`false` mutation 시 2 케이스 red 확인 후 복원(revert-green discriminator).
- **단위 격리 불가 항목 (정직)**: `durable_text` gating이 실제 `build_turn_prompt` 거대 클로저
  (ctx/meta/messages 캡처) 내부라 단위 격리 비용 과다. 가드가 named consumer를 호출하는지는 **컴파일
  green**(빌드가 가드를 type-check)으로, 실제 주입 여부는 **라이브 sanity**(flag off로 keeper 1턴 →
  프롬프트에 Memory OS facts 주입·빈 기억 아님)로 검증. 클로저 추출 테스트는 후속 리팩토링 PR로 분리.
- 빌드: `dune build` green. masc `.ocamlformat` disable=true → 관문은 컴파일.

## §6 Rollback

- Stage 1 flag default=ON → 동작 변화 0, 측정만. off는 env로 즉시 복귀.
- 각 stage 독립 PR이라 단계별 revert 가능. 가장 위험한 Stage 2(dashboard)는 표면별로 쪼개 점진 적용.
