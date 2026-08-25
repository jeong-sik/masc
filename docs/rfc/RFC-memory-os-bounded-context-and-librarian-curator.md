---
rfc: "memory-os-bounded-context-and-librarian-curator"
status: Draft
---

# RFC: Memory OS 2.0 — bounded working set 전송 계약과 librarian curator 계약

- Status: Draft
- Date: 2026-07-31
- 관련 이슈: #26527, #26530, #26531, #26532(머지), #26533
- 관련 문서: `reports/MASC-LIBRARIAN-MEMORY-OS-ADVERSARIAL-AUDIT-2026-07-30.md` (P0-5, P1-1)

## 1. 배경 — 2026-07-31 사고가 드러낸 구조

transition-audit 원장(`.masc/transition-audit/2026-07/31.jsonl`) 실측:

- `context_overflow_detected` → `overflowed` → `compacting` 진입 806회, `compaction_failed` 807회, 컴팩션 성공 0회.
- sangsu 단독 397회 실패에서 distinct `request_body_sha256`은 2개 — 바이트 동일 요청을 수백 회 재시도.
- 실패 reason의 `turn_count=2049`: checkpoint가 2,049턴까지 자라도록 어떤 감량도 없었고, chat 요청 body는 744KB에 도달.
- compaction_exact 5슬롯 전원 사망(오바인딩 404 1, ollama 주간 429 3, glm 429/미확정 1). 회복은 `keeper_clear`(기억 전소)로만 가능했다.

세 가지 사고 형태(overflow의 필연, 요약 실패 무한루프, clear 전소)의 공통 뿌리는 하나다: **checkpoint 한 파일이 세 역할 — 전송 payload, 보존 archive, 지식 원천 — 을 겸직**한다.

## 2. 문제 정의

- **P-1 전송 계약 부재.** 히스토리 전체를 매 턴 전송한다. 크기에 상한 계약이 없으므로 overflow는 사고가 아니라 이 설계의 도달점이다. 현행 완화책은 request-body cap(초과 시 거절)과 컴팩션(LLM 요약)뿐이다.
- **P-2 탈출구가 탈출 대상과 같은 자원을 요구.** 컴팩션은 LLM 호출이고, 그 호출이 필요로 하는 컨텍스트·쿼터가 바로 고갈된 자원이다. 5슬롯 rotation 전멸이 그 구조의 실측이다.
- **P-3 침묵 망각.** librarian 계약(`lib/keeper/keeper_librarian.ml`)은 `retained_memory_ids` + `new_claims`이며, 템플릿이 명문화하듯 "Any current memory ID you omit is forgotten immediately". 생략이 삭제 연산이라 의도적 망각과 모델 태만을 구분할 수 없고, lineage와 사유가 남지 않는다. 빈 retain 한 번이면 전 기억이 소실되고 복구 경로가 없다.
- **P-4 keeper-blind.** librarian 프롬프트 변수는 `current_memory`, `conversation_history` 둘뿐이다(`keeper_librarian.ml:121-125`). 시스템 템플릿은 변수 0개의 범용 한 줄이다. "이 keeper에게 무엇이 중요한가"를 판단할 재료가 입력에 없다.
- **P-5 뭉치기(consolidation) 부재.** 현행 템플릿 규칙 "Never recreate an omitted existing fact as a new claim merely to reword it"이 병합·응축을 사실상 금지한다. `keeper.librarian.memory_consolidation.md`, `keeper.librarian.episode_extraction.md` 템플릿은 코드 참조 0의 화석이다(Memory Bank 제거 잔재).
- **P-6 저널 부재.** `keeper_memory_os_current.ml`이 매 커밋 `change`(added/removed/retained)를 계산해 snapshot에 쓰지만 다음 revision이 덮어쓴다. 이전 상태와 변경 사유는 파괴된다(per-keeper 디렉토리 실측 empty).
- 감사 P1-1(coalesce로 의미 있는 turn 유실 가능)은 P-3과 결합해 침묵 손실을 키운다.

## 3. 설계

설계 전체를 두 문장으로 고정한다:

1. **처음부터 끝까지의 모든 결과를 매 턴 인스트럭션에 넣지 않는다.** payload는 구성상 유계다.
2. **librarian이 올바르게 동작하는 한 overflow 상황은 존재하지 않는다.** overflow는 처리할 사건이 아니라 librarian 정체를 알리는 알람이다.

### 3.1 3층 분리 — 전송 / 보존 / 지식

| 층 | 내용 | 계약 |
|---|---|---|
| Working set (전송) | system + keeper + facts + 최근 K턴 원문 | 매 턴 payload는 이 조합으로만 구성. 크기가 구성상 유계 |
| Archive (보존) | append-only turn 로그 (tool_use/tool_result 원문 포함) | 절대 전체 전송하지 않음. 재작성 금지. 조회는 도구로 |
| Knowledge (지식) | memory-current facts | librarian이 소유, CAS 커밋 (현행 유지) |

절단(원문을 working set에서 내리는 것)은 정보 파괴가 아니다 — 원문은 archive에 남는다. 절단 규칙:

- tool_use/tool_result 쌍 경계를 존중한다 (provider 요청 유효성).
- M턴 블록 단위로 절단한다 (prompt cache prefix 안정성).
- 감량 1순위는 오래된 tool result의 포인터 강등(참조로 대체, 원문은 archive)이다. LLM이 필요 없는 결정론 연산이다.

### 3.2 절단과 librarian의 독립성 — watermark를 두지 않는 이유

절단은 **전송 뷰에만** 작용한다. checkpoint(실록)는 온전하므로, librarian의 입력(checkpoint 꼬리에서 조립되는 최근 메시지 projection)은 전송 절단과 무관하다. "읽기 전에 잘리는" 재료는 이 구조에 존재하지 않는다 — 그 위험은 컴팩션이 원문을 파괴하던 구 설계의 것이다.

따라서 절단-librarian 동기화 기제(watermark 류)는 지킬 대상이 없는 보증이며 도입하지 않는다. librarian이 cadence 사이에 무언가를 놓치면 그것은 다음 판단이 다룰 일이지 기제가 막을 일이 아니다. **기억은 문장과 서술이고, librarian은 숫자 기준의 수집기가 아니라 기억의 정리자다.**

### 3.3 Librarian curator 계약

librarian의 정의는 한 줄이다: **keeper와 최근 N턴 맥락을 보고, keeper 대신 일기를 써주는 존재.** 무엇이 중요했는지를 문장으로 판단하고 문장으로 남긴다 — 숫자 기준의 수집기가 아니라 기억의 정리자다. 표현력과 서술이 저장 형식이다.

현행 계약을 교체하지 않고 **완성**한다. 순수 diff는 둘뿐이다: `dropped`의 reason 필드, 그리고 총체성 검증.

```
현행:  retained_memory_ids: [id]              + new_claims: [{claim, category}]
제안:  retained_memory_ids: [id]
     + dropped:            [{id, reason}]     -- 명시 망각. 사유·대체 관계 기록
     + new_claims:         [{claim, category}]
```

- **총체성**: 현재 snapshot의 모든 fact id는 `retained ∪ dropped`에 정확히 한 번 등장해야 한다. 누락 id는 커밋 거부(`Missing_disposition` — 기존 `Unknown_retained_memory_id`의 대칭). 생략은 더 이상 연산이 아니라 오류다.
- **교정과 응축은 새 op가 아니다.** "과거에 이랬는데 지금 보니 이게 맞더라" = `dropped(reason: "superseded: …") + new_claim`. 뭉치기 = `dropped×N(reason: "merged into …") + new_claim`. 별도 revise/merge/demote/promote op 타입은 도입하지 않는다 — 표현력이 동일하고(모두 "옛 항목 처분 + 새 항목"이다), lineage를 소비할 코드가 없는 상태의 타입 확장은 소비자 없는 API다. reason 문자열과 journal(§3.5)이 계보를 사람이 읽을 수 있게 남긴다.
- 현행 "reword 금지" 규칙은 "drop+add 쌍 밖에서의 재작성 금지"로 개정한다.
- 커밋 실패 비용: CAS no-commit 후 다음 cadence(3 meaningful 턴)에 재시도 — 데이터 손실이 아니라 1사이클 지연이다. 스키마가 현행과 거의 동형이므로 로컬 소형 모델의 준수율 리스크도 현행 수준이다.

### 3.4 Keeper 주입

librarian 입력에 Keeper instructions를 변수로 추가한다. 중요도·응축·망각 판단을 "이 keeper에게"로 조건화한다. 주의: live 템플릿은 `.masc/config/prompts/`의 런타임 오버라이드다 — repo 템플릿만 고치면 라이브 동작이 바뀌지 않는다(SSOT 이원화 확인 필요).

### 3.5 Memory journal — 기억의 실록

`<keeper>.memory-journal.jsonl` (append-only): 매 커밋 `{revision, ops(사유 포함), watermark, trace_id}`.

이미 계산되는 `change`의 영속화이며(신규 연산 없음), transition-audit과 동형이다. "무엇을 기록으로 남길 것인가"에 대한 답: **journal이 전부 남긴다.** librarian의 결정은 working set 재적 여부뿐이고, 망각된 fact도 journal에서 사유와 함께 추적된다.

### 3.6 Compaction의 지위와 결정론적 비상 사다리

본 설계 완성 시 컴팩션은 "없어도 동작에 문제가 없는" 기관이 된다 — 숙청 대상. 이행기 동안은 exact 실패 타이핑(#26533 인접)으로 결정론적 실패(binding/404/schema)를 terminal phase로 보내 동일 재시도 루프만 차단한다.

**진짜 overflow 상태(불변식 밖: watermark 정체로 window가 provider 한계까지 자랐거나, legacy 비대 상태)의 생존 경로에도 LLM은 없다.** 2026-07-31이 증명했듯 그 순간 LLM 호출은 가장 신뢰할 수 없는 자원이다. 비상 사다리(전부 결정론, 원문은 archive 보존):

1. 가장 오래된 구간부터 tool result 포인터 강등 — 부피 지배 항목의 기간 단위 제거.
2. 부족하면 가장 오래된 원문 블록 순 제거 (watermark 뒤 구간 우선 — 이미 fold 반영분이라 무손실).
3. 최후: watermark 앞(librarian 미반영 구간)을 제거해야 하는 경우에만 실질 손실이 발생하며, 이때는 무엇을 읽지 않고 버렸는지(구간·크기·trace)를 journal에 명시 기록한다. 침묵 손실 금지 — 손실은 허용되, 기록 없는 손실은 불허.

### 3.7 Facts 예산

working set이 "구성상 유계"이려면 모든 항이 유계여야 한다. K가 히스토리를 유계로 만들 듯, facts에도 예산이 필요하다 — 예산 없는 facts는 checkpoint를 죽인 것과 같은 병(무한 성장 컨텍스트)의 재생산이다.

- **예산 형식**: 비율이 아니라 **고정값**(config). 비율은 facts 크기를 모델 컨텍스트에 결합시켜 lane 후보마다(어느 모델의 창 기준인가) 비결정을 만든다. 값 자체는 magic number 금지 — 실측(현행 facts 크기 분포) 후 config로.
- **집행 지점**: 주입 시점이 아니라 **커밋 시점**. ops 적용 결과 총량이 예산을 넘으면 커밋 거부 — librarian이 drop으로 예산 안에 들어오도록 **결정**해야 한다. 주입 시점 절사는 침묵 손실(어떤 fact가 빠졌는지 아무도 결정하지 않음)이라 금지한다. 거절 cap(request-body cap)이 실패한 이유가 정확히 이것이다: 결정자가 없는 경계에서의 거절은 루프가 된다. 예산은 결정자가 있는 경계(커밋)에서만 의미가 있다.
- **drop은 소실이 아니다**: journal(§3.5)과 archive에 사유와 함께 남고 도구로 검색 가능하다. **별도 tier(active/deep)나 demote/promote lifecycle은 도입하지 않는다** — 검토 후 기각: journal이 이미 "내려간 기억의 저장소"이므로 tier는 journal 위의 두 번째 Facade이고, 같은 방향의 선행 구현(Memory Bank: `memory_consolidation`/`episode_extraction` 템플릿)이 제거 완료된 계보다. 죽은 개념을 타입만 바꿔 부활시키지 않는다.

### 3.8 흐름·상태 원장 (net delta)

이 RFC의 목적은 상태 추가가 아니라 흐름 정리다. 냉정한 대차대조:

| 제거되는 흐름 | 추가되는 것 |
|---|---|
| 컴팩션 요약 루프 (807 실패/일을 만든 그 흐름) | journal — append-only 관측 파일 1 (제어 흐름 소비자 없음) |
| request-body cap 거절 루프 (§4.6 재평가) | keeper — 프롬프트 변수 1 |
| 빈-retain 침묵 전멸 경로 | `dropped.reason` 필드 1 + 총체성 검증 1 |
| 화석 템플릿 2종 | (없음) |

새 lifecycle 0, tier 0, Facade 0, 파생 카운터 0, 수치 0. 신규 저장소는 journal 파일 하나다. 예외 하나를 정직하게 기록한다: 이행기 한정으로 컴팩션 결정론적 실패의 terminal phase 1개(§3.6)가 생기며, 컴팩션 숙청과 함께 소멸한다.

## 4. 이행 단계

1. **PR-A** journal (§3.5) — 계약 불변, `change` 영속화만. 소규모.
2. **PR-B** keeper 변수 주입 (§3.4) — 계약 불변, 템플릿+변수.
3. **PR-C** exact 실패 타이핑 + compaction terminal phase (§3.6 이행기, #26533과 정합).
4. curator ops 계약 교체 (§3.3) — 스키마·파서·검증·템플릿. 하네스로 준수율 측정 동반.
5. 전송 계약 (§3.1) — K/M 결정(선행 측정: agent_core checkpoint JSON에서 tool result 비중 실측), elision, archive 조회 도구.
6. 숙청 — compaction_exact lane, 화석 템플릿 2종(`memory_consolidation`, `episode_extraction`), request-body cap 재평가(§3.1이 상한을 구성으로 보장하면 거절 cap은 중복 gate).

## 5. 비제안

- **재시도 상한 / backoff / cooldown**: cap·cooldown 시그니처. 실패 타이핑(§3.6)이 root fix다.
- **빈 retain 차단기**: 총체성 계약(§3.3)이 대체한다. 차단기는 계약 부재의 보정물이다.
- **주입 시점의 facts 절사/ranking**: 침묵 손실이라 비제안. facts 유계는 §3.7의 커밋 시점 예산 계약으로만 달성한다 (결정자가 있는 경계에서의 예산 vs 결정자가 없는 경계에서의 거절 — 후자가 request-body cap의 실패 형태다).
- **revise/merge/demote/promote typed ops, active/deep 2계층 기억**: 비제안. drop(reason)+add가 동일 표현력을 가지며, lineage 소비자가 없는 타입 확장은 소비자 없는 API다. tier는 journal 위의 두 번째 Facade이자 제거 완료된 Memory Bank 계보의 부활이다 (§3.3, §3.7).
- **수치 기억 판정(가중치, 중요도 점수, recency/decay 곡선, confidence)**: 비제안. 기억의 가치 판단은 librarian의 판단(비결정론)이고, 수치 휴리스틱은 판단을 상태로 위장한 결정론이다. 현행 템플릿이 confidence 수치를 이미 제거한 선례("Do not emit a confidence number — the store no longer reads one")를 유지한다. 결정론은 운반(절단·예산 집행·보존)에만 쓴다.
- **바이트/해시 동일성 비교 기반 판정(동일 request body 반복 감지, fingerprint 카운팅)**: 비제안. 실패의 결정론성 분류는 원천의 typed 오류(binding/404/schema vs 429/timeout)에서만 온다. §1의 `request_body_sha256`은 사후 포렌식 증거일 뿐, 런타임 판정의 입력이 아니다.

## 6. 열린 질문

- K/M 값 — checkpoint 구성비 실측 후 결정 (tool result 비중이 지배적일 것으로 추정, 미검증).
- 로컬 소형 모델(현행 librarian 1순위 슬롯)의 ops 스키마 준수율.
- coalesce 드랍(감사 P1-1)의 실제 커버리지 손실 크기 — 기제 추가가 아니라 journal 실측으로 확인하고, 필요하면 cadence만 조정한다.
- archive 조회 도구의 권한 경계 (keeper 자신의 archive만인가).
- standing instruction의 명시화 경로 — 히스토리에 암묵적으로 실려 있던 "아직 유효한 옛 지시"를 system prompt/facts 중 어디로 승격하는가.
- facts 예산 값 — 현행 facts 크기 분포 실측 후 결정.
- 저접촉 낡은 확신 — 세계가 바뀌어도 반박 증거가 창에 들어오지 않으면 확신은 조용히 유지된다 (2026-07-31 실측: 접촉이 있던 확신은 정상 붕괴 — "17건 막힘"이 "실제 5건+auditor 캐시가 17로 거짓말"로 교체됨). 수치 TTL/감쇠는 비제안. 완화 후보: 검증 손잡이를 품은 서술 규범(외부 검증 가능한 형태로 쓰기), dropped.reason의 붕괴 계보, keeper 재검증 루프.
- librarian의 조사권 — 현행은 one-shot(고정 창, 도구 없음)이고 불확실성은 생략으로 해소된다. 모순/중복의 근거가 창 밖에 있으면 맥락 없이 판단하는 약점이 있다. 1차 답은 keeper 조사 루프(도구 가진 keeper가 파헤쳐 explicit_write로 결론 기록 → librarian이 정서 — 2026-07-31 ORION 실험에서 원시형 실증)이며, 도구를 가진 agentic librarian(Letta sleep-time 계보)은 journal 축적 후 창-밖 오판이 실측될 때만 검토한다.
- 입력 연관 recall(현재 입력과 가까운/연관된 기억을 골라 주입) — **명시적 future scope.** facts 전문 주입이 예산(§3.7) 안에서 동작하는 동안은 도입하지 않는다. 도입하게 되면 검색 랭킹(수치)이 필연이라 §5의 수치 판정 금지와의 경계 — "검색은 랭킹, 기억 판정은 판단" — 을 그때 별도로 그어야 한다.

## 7. 선행 연구 대조

원칙: **판단은 모델에, 기계는 운반에.** 아키텍처 계보는 채택하고, 수치 기억 판정 계보는 불채택한다.

| 계보 | 핵심 | 본 RFC와의 관계 |
|---|---|---|
| MemGPT → Letta (2023→) | 유계 main context + 외부 저장 + 도구 기반 명시 기억 편집 | §3.1 3층 분리와 동형. "Memory OS" 은유의 원류 |
| Letta sleep-time compute (2025-04) | idle 시간에 배경 에이전트가 주 에이전트의 기억을 재작성 | **librarian의 독립 재발명** — 배경 기억 에이전트 분리가 검증된 방향임을 확인 |
| Mem0 (2025) | LLM이 ADD/UPDATE/DELETE/NOOP 연산을 판단 | §3.3 계약과 동형: 연산은 소수 열거형, 판단은 모델 |
| Generative Agents (2023) | append-only memory stream + 주기적 reflection | archive + librarian cadence와 동형. 단 recency×importance×relevance **수치 스코어링은 불채택** |
| CLS 이론 (McClelland et al. 1995; Kumaran et al. 2016) | 해마(빠른 일화)–신피질(느린 의미) 이중 저장, replay 응고화 | archive=일화, facts=의미, cadence=replay. 응축은 응고화의 자연 위치 — 연산 추가 없이 drop+add로 수행 |
| AGM belief revision, Levi identity (1985) | revision = contraction ∘ expansion | "교정 = drop + add"의 이론적 근거 — 최소 연산 집합이 원리적으로 완비 |
| HippoRAG 1/2 (2024–25) | KG 해마 인덱스 + PPR 연상 검색, continual learning | §6 future scope(연관 recall)의 후보 기술. 수치 랭킹 내장이라 도입 시 §5 경계 논의 필수 |
| OpenClaw (2025–26) | 기억=마크다운 파일: MEMORY.md(큐레이션 장기) + 일일 노트(일화), **오늘+어제만 로드**, 배경 "Dreaming" 응고화 | 3층 분리·시간형 K·librarian의 대규모 배포 선례. 코어에 vector DB·수치 스코어 없음 — 극단 심플 계보의 생존 증명 |
| Hermes Agent (Nous, 2026-02) | profile별 fact 저장(SQLite FTS5 검색) + SOUL.md 정체성 문서 + 성공/실패 학습 | facts 저장 + 결정론 검색(FTS)의 선례. SOUL.md = keeper 주입(§3.4)의 선례 |
| 2025–26 서베이 계열 | "working memory는 검색 문제가 아니라 **context-budget 문제**"; 기억 lifecycle = formation/evolution/retrieval | R1·§3.7 예산과 일치. Ebbinghaus류 수치 망각 곡선은 불채택 |

수렴 관찰: 일곱 독립 계보(MemGPT/Letta, Mem0, Generative Agents, CLS, AGM, OpenClaw, Hermes)가 — 2026년 최다 배포 에이전트 두 개를 포함해 — 같은 형태로 수렴한다: **유계 작업 기억 + 작은 큐레이션 기억 + append-only 원장 + 배경 판단자의 소수 연산 + 필요시 검색.** 본 RFC가 새로 발명하는 기제는 없다 — 이 수렴 형태를 masc에 이미 있는 파일들(checkpoint, memory-current, keeper toml)에 그대로 사상하며, 신규물은 journal 파일 하나다.
- 비상 사다리 3단(watermark 앞 절단)의 손실 기록 형식과, 그 상태를 운영 표면(#26531)에 어떻게 노출하는가.
