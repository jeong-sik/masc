---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
  - lib/tool_dispatch.ml
  - lib/server/
---

# Inventory Gap Analysis RFC

**Status**: Draft
**Date**: 2026-03-29
**Scope**: MASC-MCP full product surface
**Version at analysis**: v2.161.0 (dune-project), 305+ MCP tools, 289K LOC
**One sentence**: 문서가 약속하는 기능과 실제 작동하는 기능의 차이를 정량 검증하여, 17개 갭을 4-Wave 해결 계획으로 정리한다.

## Related Documents

- `../PRODUCT-REVIEW.md`
- `../PRODUCT-OPERATING-PLAN.md`
- `../MCP-SURFACE-AUDIT.md`
- `./keeper-memory-resurrection-rfc.md`
- `./contract-driven-agent-loop-rfc.md`
- `./oas-masc-state-boundary.md`
- `../../ROADMAP.md`
- `../../CHANGELOG.md`

## Methodology

3축 병렬 검증:

1. **문서 선언**: PRODUCT-OPERATING-PLAN, PRODUCT-REVIEW, ROADMAP, CHANGELOG, spec/ 에서 약속된 기능 수집
2. **실제 구현**: tool_dispatch.ml 등록, handler .ml 파일, 파일시스템 상태 (.masc/ 디렉토리) 직접 확인
3. **갭/이슈**: GitHub issues, TODO/FIXME 패턴, git history, handoff 문서 교차 분석

각 갭은 "문서가 약속 → 파일시스템/코드에서 부재 확인 → 증거 기록" 경로로 검증됨.

---

## 1. Problem Statement

masc-mcp는 95.2% 구현율(spec/C-implementation-status.md)을 보고하지만, 이 수치는 "코드가 존재하는가"를 측정한다.
"코드가 production 경로에 연결되어 작동하는가"는 별개 질문이다.

분석 결과:

- 구현되었으나 production 경로에 연결되지 않은 dead code가 체계적으로 존재한다.
- 12개 도구가 deprecation 공지 없이 dispatch에서 제거되었다.
- 4개 문서가 서로 다른 버전 번호를 보고한다.
- 핵심 가치 제안("자율 에이전트 + 영속 메모리")이 실질적으로 미작동한다.

이 RFC의 목적은 "있어야 하는데 없는 것"을 분류하고, 해결 순서를 정하는 것이다.

## 2. Non-Goals

- 새로운 기능을 제안하지 않는다. 기존 약속의 이행 여부만 다룬다.
- 아키텍처 재설계를 제안하지 않는다. 기존 구조 내에서 해결 가능한 범위만 다룬다.
- target:later 항목(package 추출, cluster mode, binary distribution)은 다루지 않는다.

---

## 3. Design Principle: Deterministic-Nondeterministic Boundary

이 RFC의 모든 해결 방향은 다음 원칙을 따른다.

### 3.0.1 정의

- **결정론적 (Deterministic)**: 동일 입력 → 동일 출력. 시스템이 보장하는 동작. 실패하면 버그.
- **비결정론적 (Nondeterministic)**: 동일 입력 → 다른 출력 가능. LLM 추론, 확률적 선택, 외부 의존.

### 3.0.2 원칙

1. **결정론적 동작을 비결정론적 출력에 의존시키지 않는다.**
   - 예: memory write는 시스템이 보장해야 하는 결정론적 동작. LLM이 특정 포맷(`[STATE]`)을 출력하기를 "기대"하는 것은 비결정론적 출력에 결정론적 동작을 결합한 설계 오류.
   - 예: health check 결과는 실제 bind/listen 상태의 결정론적 반영이어야 함. stale state machine은 비결정론적 드리프트.

2. **비결정론적 요소는 명시적으로 격리한다.**
   - LLM 출력의 **내용**(무엇을 기억할지)은 비결정론적일 수 있다.
   - LLM 출력의 **처리**(기억하는 행위 자체)는 시스템 소유의 결정론적 경로여야 한다.
   - tool call은 내용을 더 잘 싣는 보조 경로일 수 있지만, 호출 여부 자체는 모델 행동이므로 단독 guarantee path가 될 수 없다.
   - 경계: `f(nondeterministic_input) → deterministic_side_effect` 는 허용. `if nondeterministic_format then deterministic_action` 은 금지.

3. **결정론적 경로에는 결정론적 검증을 붙인다.**
   - CI gate, type check, schema validation은 결정론적. 이들이 통과하면 항상 올바르다.
   - "수동 동기화", "운영자가 확인", "모델이 포맷을 따르기를 기대"는 비결정론적 검증. 이들은 보조 수단이지 보장이 아니다.

### 3.0.3 각 갭의 경계 위반 분류

| 갭 | 위반 유형 | 설명 |
|----|----------|------|
| C1 | **비결정론적 출력 → 결정론적 동작 의존** | `[STATE]` 포맷 파싱이 memory write의 전제조건 |
| C2 | 결정론적 기능 부재 | config 직렬화는 결정론적이나 도구 노출이 없음 |
| H1 | 결정론적 lifecycle 부재 | deprecation state machine 없이 수동 제거 |
| H2 | **결정론적 스키마 ≠ 비결정론적 런타임** | 스키마가 기능 존재를 선언하나 런타임이 항상 실패 |
| H3 | 결정론적 contract 부재 | API shape가 명세되지 않아 클라이언트가 결정론적으로 파싱 불가 |
| H4 | **비결정론적 검증 (수동 동기화)** | CI gate 없이 4개 문서의 버전 일치를 수동으로 보장 |
| H5 | 결정론적 flag 평가 부재 | 하드코딩 1개만 존재, 동적 평가 경로 없음 |
| M1 | 결정론적 정합성 부재 | deny list가 구현 존재를 가정하나 검증 없음 |
| M2 | — | 아키텍처 부채, 경계 문제 아님 |
| M3 | 결정론적 contract 미완성 | CDAL의 pass/fail gate가 정의되지 않음 |
| M4 | 결정론적 경계 위반 | OAS가 MASC 도메인 용어를 직접 참조 |
| M5 | **결정론적 동작에 비결정론적 타이밍** | GC 소요시간이 heartbeat 타이밍을 비결정론적으로 지연 |
| M6 | **결정론적 상태 ≠ 결정론적 보고** | 실제 bind 상태와 보고 상태가 독립적으로 드리프트 |
| I4 | 결정론적 파싱 불가 | 에러 shape가 자유형이라 클라이언트가 결정론적으로 분류 불가 |

---

## 4. Gap Inventory

### 4.0 Severity Classification

| 등급 | 기준 | 개수 |
|------|------|------|
| CRITICAL | 핵심 제품 약속 위반. 사용자가 기대하는 기본 동작이 실패 | 2 |
| HIGH | 제품 신뢰도 훼손. 운영자/개발자 경험에 직접 영향 | 5 |
| MEDIUM | 아키텍처 부채. 현재 작동하지만 확장/유지보수 차단 | 6 |
| INFERRED | 패턴 분석에서 추론됨. 직접 이슈 없으나 위 갭들의 근본 원인 | 4 |

---

### 4.1 CRITICAL

#### C1: Keeper 영속 메모리 시스템 미작동

**Issue**: #3630
**약속**: Keeper는 "자율 에이전트 + 영속 메모리"로 문서화됨 (KEEPER-USER-MANUAL.md, QUICK-START.md)
**현실**: 46개 keeper 디렉토리, memory.jsonl 0개

**증거**:

```bash
# 파일시스템 직접 확인 (2026-03-29)
find .masc/keepers -name "memory.jsonl" | wc -l
# 결과: 0
ls .masc/keepers/ | wc -l
# 결과: 46
```

**근본 원인 (7중 실패)**:

| # | 위치 | 상태 | 문제 |
|---|------|------|------|
| G1 | `keeper_memory_bank.ml:372` `append_memory_notes_from_reply` | 구현됨 | 호출자 0개 |
| G2 | `memory_oas_bridge.ml:129` `seed_memory_bank` | 의도적 no-op | return 0, 테스트에서도 0 assert |
| G3 | `keeper_memory_bank.ml:204` `compact_memory_bank_if_needed` | 구현됨 | 호출자 0개 |
| G4 | `keeper_memory_policy.ml:374` `[STATE]` 블록 파서 | 구현됨 | system prompt에 포맷 주입 안 됨 |
| G5 | keeper constitution prompt | 정의됨 | `build_keeper_system_prompt`에서 미사용 |
| G6 | 로컬 모델 (qwen3.5) | 작동 | 강제 없이 `[STATE]` 포맷 생성 불가 |
| G7 | `keeper_agent_run.ml:195` | 대화 히스토리 전달됨 | checkpoint 부재 + `keep_last 30` reducer 절삭 |

**기존 RFC**: `docs/design/keeper-memory-resurrection-rfc.md` (G1-G7 식별, 단계별 해결 제안)

**기존 RFC의 근본 문제**:

기존 RFC는 G4-G6 (system prompt에 `[STATE]` 포맷 주입 → LLM이 해당 포맷 출력 → 파서가 인식 → memory write)을 해결 경로로 제안한다. 이것은 **비결정론적 출력에 결정론적 동작을 의존**시키는 휴리스틱이다.

- LLM이 `[STATE]` 포맷을 출력할 확률은 모델, temperature, context length에 따라 달라진다.
- 로컬 모델(qwen3.5-9b)은 강제 없이 이 포맷을 거의 생성하지 않는다.
- system prompt 주입으로 확률을 높일 수 있지만, **확률이 1이 아닌 이상 결정론적 보장이 아니다.**
- "포맷을 더 잘 따르도록 프롬프트를 개선"하는 접근은 문제를 완화하지만 해결하지 않는다.

**올바른 해결 방향 (결정론적/비결정론적 분리)**:

| 계층 | 성격 | 설계 |
|------|------|------|
| **Memory write 행위** | 결정론적 (시스템 보장) | 매 턴 종료 후 시스템 소유 post-turn 경로가 무조건 memory write를 수행. LLM 출력 포맷이나 tool call 존재 여부에 의존하지 않음 |
| **Memory 내용 생성** | 비결정론적 (LLM 추론) | 턴의 대화 내용을 요약/추출하는 것은 LLM이 하되, 이것은 별도 요약 호출 또는 선택적 tool call |
| **Memory 내용 부재 시** | 결정론적 fallback | LLM 요약이 실패하더라도, raw turn transcript를 그대로 memory에 저장 (degraded but guaranteed) |

구체적으로 세 가지 접근이 가능하다:

**A. Tool-based memory (선택적 보조 경로)**:
- `keeper_memory_save` tool을 keeper에게 노출
- keeper가 tool call로 명시적으로 memory write
- tool call이 발생하면 dispatch와 write 자체는 결정론적
- 단, tool call 발생 여부는 모델 행동이므로 이것만으로는 memory write guarantee가 되지 않음
- 따라서 system prompt 지시는 품질 향상 수단일 뿐, 단독 해결책이 아님

**B. Post-turn forced summarization (필수 guarantee path)**:
- `keeper_agent_run.ml`에서 매 턴 종료 시, 시스템 소유 경로로 별도 LLM 호출 또는 deterministic transform을 실행
- 생성된 요약/추출 결과를 `keeper_memory_bank.ml`의 write path로 강제 전달
- LLM 요약 호출 자체가 실패하면 raw transcript fallback
- 비용: 턴당 1회 추가 LLM 호출

**C. Structured output constraint (constrained decoding)**:
- LLM 출력에 structured output / JSON mode 강제
- memory 관련 필드를 response schema에 포함
- 이것은 모델이 지원하는 경우에만 결정론적 (llama.cpp JSON grammar, Claude tool_use)
- 모든 모델에서 보장되지 않으므로 단독 사용 불가

**권장**: B를 guarantee path로 두고, A를 선택적 enrichment path로 결합한다. 즉 system-owned post-turn write가 항상 실행되고, tool call은 salience/selection 품질을 높일 때만 추가한다. 두 경로 모두 LLM 출력 **포맷**에 의존하지 않는다.

**기존 RFC와의 관계**: 기존 RFC의 G1-G3 (dead code 활성화)와 G7 (checkpoint)은 유효. G4-G6 (`[STATE]` 포맷 의존)은 위 접근으로 대체.

**예상 노력**: 5-7일 (기존 추정 3-5일에서 증가. tool 정의 + post-turn hook + fallback + E2E 테스트)

---

#### C2: Config Introspection 도구 부재

**Issues**: #3364, #3365, #3363
**약속**: PRODUCT-OPERATING-PLAN.md Capability Posture 테이블에 "Config introspection" 행 존재
**현실**: "Not done for product promise" 명시. MCP 도구 0개.

**증거**:

```bash
# tool_dispatch.ml에서 config 도구 검색 (2026-03-29)
grep -n "masc_config" lib/tool_dispatch.ml
# 결과: 0건

# 직렬화 레이어는 존재
grep -n "to_json" lib/config/env_config.ml | head -3
# Env_config.to_json() 존재
```

**phantom 참조**: `keeper_hooks_oas.ml:36-37`에서 `masc_config_set`, `masc_config_reset`을 deny list에 등록하지만 구현 없음.

**해결 방향**: `Env_config.to_json()`을 read-only MCP 도구로 래핑. write 경로는 auth 설계(H3) 이후.
**예상 노력**: 2-3일

---

### 4.2 HIGH

#### H1: 12개 도구 무공지 삭제

**Commit**: cd3716c30 (2026-03-29)

| 카테고리 | 도구 | 개수 |
|----------|------|------|
| ~~Tempo~~ | ~~`masc_tempo`, `masc_tempo_adjust`, `masc_tempo_get`, `masc_tempo_reset`, `masc_tempo_set`~~ | ~~5~~ (removed PR #4750) |
| ~~Encryption~~ | ~~`masc_encryption_enable`, `masc_encryption_disable`, `masc_encryption_status`, `masc_generate_key`~~ | ~~4~~ (removed PR #4750) |
| Notifications | `masc_notification_count`, `masc_check_notifications`, `masc_consume_notifications` | 3 |

**증거**:

```bash
# dispatch 등록 확인 (2026-03-29)
grep "masc_tempo\|masc_encryption\|masc_notification\|masc_generate_key" lib/tool_dispatch.ml
# 결과: 0건

# historical snapshot (2026-03-29): 당시 handler 파일은 잔존
ls lib/tool_tempo.ml lib/tool_encryption.ml lib/tool_notifications.ml
# 모두 존재
```

- CHANGELOG에 deprecation/removal 기록 없음
- handler .ml 파일이 dead code로 컴파일되어 115-module SCC에 기여

**해결 방향 (결정론적 lifecycle)**:

도구 삭제가 CHANGELOG에 기록되지 않은 것은 결정론적 lifecycle이 없기 때문이다.

1. **Deprecation state machine 도입**: `Active → Deprecated(version) → Removed(version)`. 각 전환에 CHANGELOG 기록을 강제.
2. **`tool_catalog.ml`의 Deprecated variant 활용**: 이미 `Deprecated` lifecycle variant가 존재. dispatch에서 제거하는 대신 Deprecated로 전환하면 호출 시 경고를 반환.
3. **Dead handler 삭제**: tempo, encryption, notifications handler .ml 파일 삭제. 이미 dispatch에서 제거되었으므로 복원이 아닌 정리.
4. **CI lint**: `lib/tool_*.ml` 중 `tool_dispatch.ml`에 등록되지 않은 handler가 있으면 경고.

**예상 노력**: 1-2일

---

#### H2: Voice Transcript stub이 실제 도구로 광고됨

**파일**: `lib/tool_voice.ml:230`
**약속**: MCP 스키마에 `agent_id, format, language, quality` 파라미터까지 완전 정의
**현실**: lib/ 전체에서 유일한 `not_implemented` 반환

```ocaml
let handle_voice_transcript (_ctx : 'a context) _args : result =
  (false, Yojson.Safe.to_string
    (`Assoc
      [ ("error", `String "not_implemented");
        ("message", `String "masc_voice_transcript requires an external STT service...") ]))
```

다른 voice 도구(speak, session, conference)는 정상 작동.

**해결 방향 (결정론적 스키마-런타임 일치)**:

스키마가 선언하는 기능과 런타임이 제공하는 기능이 결정론적으로 일치해야 한다. "스키마에 있지만 항상 실패"는 스키마 거짓말.

1. **제거가 기본**: 구현이 없으면 스키마에서 제거. 클라이언트가 존재하지 않는 기능을 호출하는 것보다, 처음부터 보이지 않는 것이 낫다.
2. **미래 구현 계획이 있으면**: MCP tool schema에 `"status": "planned"` 또는 `"available": false` annotation. 단, MCP spec이 이를 지원하는지 확인 필요.
3. voice transcript의 경우: 외부 STT 서비스 의존이므로, 서비스 없이는 영구 불가. 스키마에서 제거.

**예상 노력**: 0.5일

---

#### H3: Auth/API Contract 미완성

**문서**: PRODUCT-REVIEW.md lines 59-67
**약속**: "Remote-safe or ops-grade posture"가 promise stack level 4
**현실**: "Not ready as a product promise"

- auth defaults가 trusted-network 가정에 의존
- REST/SSE contract가 불분명
- API 버전 헤더/스킴 없음

**해결 방향**: 설계 먼저 (auth model, API versioning, error shape). C2의 write 경로에도 필요.
**예상 노력**: 5-8일

---

#### H4: 릴리즈 버전 4-way 드리프트

**약속**: ROADMAP.md line 81: "Do not tag a release while version truth is broken"

**증거** (2026-03-29 직접 확인):

| 파일 | 버전 |
|------|------|
| `dune-project` | 2.161.0 |
| `masc_mcp.opam` | 2.161.0 |
| `CHANGELOG.md` 최신 | 2.160.0 |
| `ROADMAP.md` | 2.159.0 |
| `PRODUCT-OPERATING-PLAN.md` | 2.153.0 |

4개 문서, 4개 다른 버전. CI 동기화 게이트 없음.

**해결 방향 (결정론적 보장)**:

현재 접근(수동 동기화)은 비결정론적 검증이다. 올바른 접근:

1. **SSOT를 1개로 줄인다**: `dune-project`의 `(version X.Y.Z)`이 유일한 진실.
2. **파생 문서는 빌드 타임에 생성한다**: ROADMAP, PRODUCT-OPERATING-PLAN의 버전 문자열을 `dune-project`에서 추출하여 주입하거나, CI가 불일치를 컴파일 에러 수준으로 차단.
3. **CI pre-commit hook**: `scripts/check-version-truth.sh`가 dune-project vs opam vs CHANGELOG vs ROADMAP을 비교하여, 불일치 시 커밋 자체를 거부.
4. CHANGELOG의 `[Unreleased]` → `[X.Y.Z]` 전환은 release script에서 자동화.

핵심: "동기화를 잊지 않기를 기대"하는 대신 "불일치 시 빌드가 실패"하도록 만든다.

**예상 노력**: 1-2일

---

#### H5: Feature Flag 인프라 부재

**Issue**: #3522
**약속**: CDAL RFC에서 feature flag 기반 progressive rollout 전제

**현실**:
- 유일한 플래그: `MASC_DISPATCH_V2` (env_config_runtime.ml, 하드코딩, v2.102 이후 기본 ON)
- 동적 flag 레지스트리 없음
- flag 평가 API 없음
- A/B 테스트 지원 없음

**해결 방향**: flag 레지스트리 (env/file backend) + 평가 API + dashboard 가시성
**예상 노력**: 3-5일

---

### 4.3 MEDIUM

#### M1: Phantom Tools — deny list의 유령 12개

**파일**: `lib/keeper/keeper_hooks_oas.ml:27-48`

deny list에 등록되었으나 구현이 없는 도구:

```
masc_config_set          → C2 관련, 구현 없음
masc_config_reset        → C2 관련, 구현 없음
masc_room_delete         → 구현 없음
masc_room_destroy        → 구현 없음
masc_admin_reset         → 구현 없음
masc_admin_cleanup       → 구현 없음
masc_spawn               → tool_tag_init에 이름만 등록, handler 없음
masc_execute             → 구현 없음
masc_execute_dry_run     → 구현 없음
masc_neo4j_query         → 구현 없음
masc_pg_query            → 구현 없음
```

**해결 방향**: forward-looking 항목은 주석으로 명시, 나머지 제거
**예상 노력**: 0.5일

---

#### M2: 115-Module 순환 의존

**Issue**: #3593 (target:now)

- 586 모듈, 1961 의존 엣지
- 최대 SCC: 115개 모듈 (전체의 20%)
- Hub: Room (139 dependents), Tool_args (59), Keeper_types (44)
- Tool↔Keeper 순환이 핵심 원인
- worktree `refactor/3593-scc-quick-fixes` 존재, Phase 0만 완료

**해결 방향**: dead code 제거(H1) → interface 추출 → dune library 분할
**예상 노력**: 15-30일 (multi-phase)

---

#### M3: CDAL PoC-1 미완성

**Issue**: #3528 (implementation tracker)

- Phase 0 eval은 v2.160.0에 포함 (CHANGELOG 확인)
- Critical gates 미해결: #3514 (risk_contract), #3515 (proof bundle), #3516 (composition), #3517 (JSON schema)
- Blocking decisions: artifact store backend, threshold numbers, labeling protocol freeze
- PoC-2 PR (#3613-3615) 리뷰 결과 병합 불가 (RFC 미준수, path traversal, typed verdict 미연동)

**해결 방향**: gate-by-gate 순차 해결
**예상 노력**: 8-12일

---

#### M4: OAS 경계 위반

**Issue**: #3588 (target:now)
**원칙**: "OAS must never know MASC exists" (docs/OAS-MASC-BOUNDARY.md)

- bridge 레이어(`memory_oas_bridge.ml`, `team_session_oas_bridge.ml`)에서 경계 교차
- OAS-MASC-BOUNDARY.md 자체가 "Partial complete" 인정

**해결 방향**: bridge 레이어 audit → MASC 도메인 용어 제거 → 인터페이스 순수화
**예상 노력**: 3-5일

---

#### M5: GC 멀티룸 커플링

**Issue**: #3626

- 좀비 cleanup이 서버 Pulse에 묶여 있음
- Pulse 소비자 목록이 순차 처리
- 한 룸의 GC가 전체 heartbeat 차단

**해결 방향 (결정론적 타이밍 보장)**:

GC 소요시간이 비결정론적(좀비 수, 파일 크기에 따라 변동)이므로, 결정론적 타이밍이 필요한 heartbeat와 같은 Pulse를 공유해서는 안 된다.

1. **분리 원칙**: 결정론적 타이밍이 필요한 동작(heartbeat)과 비결정론적 소요시간의 동작(GC)을 같은 sequential consumer loop에 넣지 않는다.
2. **구현**: GC를 별도 Eio fiber로 분리. Pulse는 heartbeat만 담당. GC는 자체 주기 또는 이벤트 트리거.
3. **검증**: heartbeat 간격의 jitter를 측정. GC 실행 중에도 heartbeat 간격이 설정값 +/- 10% 이내인지 확인.

**예상 노력**: 3-5일

---

#### M6: Transport Health 진실 불일치

**Issue**: #3408 (ROADMAP target:now)

- gRPC discovery가 `listening=false` 보고하지만 실제로는 도달 가능
- health check와 실제 상태 불일치

**해결 방향 (결정론적 상태 반영)**:

health check 결과는 실제 상태의 결정론적 반영이어야 한다. "state machine이 이전 상태를 캐싱"하는 것은 비결정론적 드리프트.

1. **상태 추출을 직접 수행**: discovery가 state machine을 참조하는 대신, 실제 소켓/포트에 probe를 보내서 결과를 반환.
2. **캐싱이 필요하면 TTL 명시**: 캐시된 상태에는 TTL을 부여하고, 만료 시 `unknown`을 반환. `listening=false`(확정적 거짓)보다 `unknown`(정직한 무지)이 낫다.
3. **검증**: gRPC 서버 실행 중 `masc_transport_status`가 `listening=true`를 반환하는지 E2E 테스트.

**예상 노력**: 2-3일

---

### 4.4 INFERRED (패턴 기반)

#### I1: Keeper E2E 메모리 통합 테스트 부재

346개 테스트 파일 중 "keeper에게 N턴 보내고 recall 검증"하는 통합 테스트 없음.
`test_memory_oas_5tier.ml:383`이 `seed_memory_bank` 반환값 0을 assert하여 no-op을 "정상"으로 취급.

#### I2: Dead Code 축적 패턴

C1 (3개 미호출 함수), H1 (12개 dead handler), `seed_memory_bank` no-op 등 공통 패턴: "기능을 구현하되 production 경로에 연결하지 않고 방치." 단일 lib/ 컴파일 단위(M2)가 이를 은폐.

#### I3: 파일시스템 스토리지 마이그레이션 프레임워크 부재

`.masc/` 디렉토리 구조 변경 시 (예: legacy naming cleanup #3627) 자동화된 마이그레이션 경로 없음. 수동 rename만 존재.

#### I4: 도구 간 에러 형태 불일치

305+ 도구에 통일된 에러 타입 없음. Voice는 `{"error": "not_implemented"}`, 다른 도구는 자유형 문자열. MCP 클라이언트가 에러 카테고리를 프로그래밍적으로 구분 불가.

**결정론적 원칙 적용**: 에러 shape는 결정론적으로 파싱 가능해야 한다. 자유형 문자열은 비결정론적 — 클라이언트가 패턴 매칭이나 substring 검색에 의존하게 된다. OCaml variant type으로 에러 카테고리를 정의하고, JSON 직렬화 시 `{"error_code": "not_implemented", "message": "..."}` 형태의 결정론적 shape를 보장해야 한다. H3(API Contract)과 함께 해결.

---

## 5. Dependency Map

```
H4 (Release Truth) ─── unblocks ──→ 모든 릴리즈
H1 (Dead Tools)    ─── feeds ────→ M2 (순환 의존 축소)
C1 (Keeper Memory) ─── touches ──→ M4 (OAS 경계)
C2 (Config)        ─── needs ───→ H3 (Auth) for write path
H5 (Feature Flags) ─── enables ──→ C1, C2 안전 롤아웃
M2 (순환 의존)     ─── blocks ──→ package 추출 (target:later)
M6 (Transport)     ─── blocks ──→ dashboard 신뢰, H3 (원격 운영)
M3 (CDAL)          ─── feeds ───→ keeper proof 품질
M5 (GC 커플링)     ─── affects ─→ keeper 안정성, C1 효과
```

## 6. Resolution Plan

### Wave 1: Truth and Hygiene (1-2 weeks)

목표: 제품 진실성 회복. 가장 빠르게 실행 가능한 항목.

| 순서 | 갭 | 노력 | 산출물 |
|------|-----|------|--------|
| 1 | H4: Release Truth Drift | 1-2일 | 4개 문서 동기화 + CI gate |
| 2 | H1: Dead Tool 제거 | 1-2일 | 3개 handler 삭제 + CHANGELOG 기록 |
| 3 | M1: Phantom Tool 정리 | 0.5일 | deny list 주석 정비 |
| 4 | H2: Voice Stub 정리 | 0.5일 | 스키마에서 제거 또는 annotation |

Wave 1 완료 조건: `scripts/check-version-truth.sh` green + dead handler 0개 + CHANGELOG 기록

### Wave 2: Core Capability Restoration (2-3 weeks)

목표: 핵심 약속 이행. C1은 기존 RFC를 따름.

| 순서 | 갭 | 노력 | 산출물 |
|------|-----|------|--------|
| 5 | C1: Keeper Memory | 5-7일 | tool-based memory + post-turn fallback + E2E 테스트 (I1 해소) |
| 6 | C2: Config Introspection | 2-3일 | `masc_config` read-only consolidation |
| 7 | M6: Transport Health | 2-3일 | gRPC listening 상태 수정 |

Wave 2 완료 조건: `find .masc/keepers -name "memory.jsonl" | wc -l` > 0 + config 도구 등록 확인

### Wave 3: Architecture and Contract (3-6 weeks)

목표: 확장 기반 마련.

| 순서 | 갭 | 노력 | 산출물 |
|------|-----|------|--------|
| 8 | H5: Feature Flags | 3-5일 | flag 레지스트리 + 평가 API |
| 9 | M5: GC 디커플링 | 3-5일 | per-room GC 또는 Pulse 분리 |
| 10 | H3: Auth/API | 5-8일 | auth 설계 문서 + 기본 구현 |
| 11 | M4: OAS 경계 | 3-5일 | bridge audit + 도메인 용어 제거 |

### Wave 4: Structural (6+ weeks)

목표: 장기 유지보수성.

| 순서 | 갭 | 노력 | 산출물 |
|------|-----|------|--------|
| 12 | M2: 115-Module 순환 | 15-30일 | SCC 크기 50% 감소 |
| 13 | M3: CDAL PoC-1 | 8-12일 | gate #3514-3517 해결 |

---

## 7. Effort Summary

| 등급 | 갭 수 | 총 예상 노력 |
|------|-------|-------------|
| CRITICAL | 2 | 7-10일 |
| HIGH | 5 | 11-17일 |
| MEDIUM | 6 | 32-55일 |
| **합계** | **13 (+ 4 inferred)** | **50-82 person-days** |

---

## 8. Key Files

| 파일 | 갭 | 역할 |
|------|-----|------|
| `lib/keeper/keeper_memory_bank.ml` | C1 | dead write/read/compact 경로 |
| `lib/keeper/keeper_agent_run.ml` | C1 | memory recall 연결점 |
| `lib/memory_oas_bridge.ml` | C1, M4 | 의도적 no-op, OAS 경계 |
| `lib/keeper/keeper_hooks_oas.ml` | M1 | 12개 phantom tool deny list |
| `lib/config/env_config.ml` | C2 | `to_json()` 래핑 필요 |
| `lib/tool_voice.ml` | H2 | 유일한 `not_implemented` stub |
| `lib/tool_tempo.ml` | H1 | dead handler (PR #4750에서 제거) |
| `lib/tool_encryption.ml` | H1 | dead handler (PR #4750에서 제거) |
| `lib/tool_notifications.ml` | H1 | dead handler (삭제 대상) |
| `lib/tool_dispatch.ml` | H1, C2 | 도구 등록 중앙 |
| `dune-project` | H4 | 버전 SSOT |
| `ROADMAP.md` | H4 | 버전 drift |
| `PRODUCT-OPERATING-PLAN.md` | H4 | 버전 drift |

## 9. Verification

```bash
# H4: 버전 동기화
DUNE_VER=$(grep "^(version" dune-project | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
CL_VER=$(grep "^\## \[" CHANGELOG.md | head -2 | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
RM_VER=$(grep "Current package version" ROADMAP.md | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "dune=$DUNE_VER changelog=$CL_VER roadmap=$RM_VER"

# H1: dead handler 제거 확인
for f in tool_tempo tool_encryption tool_notifications; do
  test -f "lib/${f}.ml" && echo "FAIL: lib/${f}.ml still exists" || echo "OK: ${f} removed"
done

# C1: keeper memory 존재 확인
find .masc/keepers -name "memory.jsonl" -o -name "memory_bank.jsonl" | wc -l

# C2: config 도구 등록 확인
grep -c "masc_config" lib/tool_dispatch.ml

# M1: phantom tool 정리 확인
grep "masc_config_set\|masc_room_delete\|masc_admin_reset\|masc_spawn\|masc_execute\b\|masc_neo4j_query\|masc_pg_query" \
  lib/keeper/keeper_hooks_oas.ml | grep -v "(\*" | wc -l
# 주석 처리되지 않은 phantom 항목 수 (목표: 0 또는 forward-looking 주석 포함)
```

## 10. Open Questions

1. **H1 도구 복원 여부**: tempo, encryption, notifications 중 향후 다시 필요한 도구가 있는가? 있다면 삭제 대신 deprecated 마킹.
2. **C2 write 경로**: `masc_config_set`을 구현할 것인가, read-only로 제한할 것인가? auth 설계(H3) 선행 필요.
3. **M2 분해 우선순위**: SCC에서 먼저 추출할 모듈 그룹은? Phase 0 리포트의 coupling 분석 기반으로 결정.
4. **I3 마이그레이션 프레임워크**: 별도 이슈로 추적할 것인가, keeper 리네이밍(#3627) 작업에 포함할 것인가?
