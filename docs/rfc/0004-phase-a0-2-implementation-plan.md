# RFC-0004 Phase A0.2 — implementation plan (TS decoder + golden replay + CLI emitter)

Status: Draft (2026-05-17)
Companion to: docs/rfc/RFC-0004-shared-contract-ocaml-ts.md §Phase A0
Predecessor: docs/rfc/0004-phase-a0-1-implementation-plan.md (Completed 2026-05-17)
Related: PR #7955 (dashboard manual SSE schema, current TS boundary), PR #15807-#15849 (Phase A0.1 sprint)

## 1. 작업 범위 재정의

Phase A0.1 완료 상태 (2026-05-17):

- `lib/sse_event/sse_event.atd` 가 16 SSE event 의 typed schema SSOT
- `lib/cascade/cascade_event_bridge.ml` 의 모든 publish arm 이 `Sse_event` typed constructor 경유
- `test/sse_event/test_sse_event.ml` 의 19 byte-equal test 가 wire envelope SSOT 고정

Phase A0.2 의 정확한 작업 = **이 SSOT 를 TypeScript 측에서도 사용하게 만드는 것**. 이 작업이 없으면 dashboard 의 `schemas/sse.ts` (현재 manual schema-like, ~310 LOC) 가 wire format 변경마다 drift 위험에 노출.

## 2. 현재 TS 측 상태 (audit, 2026-05-17)

```
dashboard/src/schemas/sse.ts        310 LOC  manual schema-like (PR #7955)
dashboard/src/types/sse.ts          354 LOC  manual TS interfaces
```

`schemas/sse.ts` 의 특징:
- zod 같은 generic schema runtime 미사용 ("avoids pulling a generic schema runtime into the dashboard hot path")
- 자체 `SchemaLike<T>` 인터페이스 (`parse` / `safeParse` 모양)
- `FIXED_SSE_EVENT_TYPES` 같은 closed enum set 을 module-level Set 으로 관리

`types/sse.ts` 의 특징:
- 모든 16 event 의 union type `SSEEvent` 수동 정의
- `Attribution`, `AttributionOutcome` 등 OCaml 측 보조 type 동등 정의

**Drift 위험 site**:
1. OCaml 측이 새 event 추가 (e.g. PR-1~3b 처럼) → TS 가 모르면 `SSEEvent` discriminated union 의 default branch 가 silently 받음
2. OCaml payload field 추가 → TS interface 가 모르면 type assertion 우회로 read
3. OCaml 의 `json_string_opt` (empty string → null) 같은 비표준 coercion → TS 가 모르면 `.trim()` 호출 시 null → IDE crash 재발

→ Phase A0.2 의 SSOT 도입은 이 3 drift site 의 **컴파일 타임 차단**이 목표.

## 3. atd → TypeScript pipeline 옵션 분석 (open question)

| 옵션 | 도구 | 산출물 | 장점 | 단점 |
|---|---|---|---|---|
| **A. atdgen-ts (또는 atd-ts)** | `atdgen-ts` (ahrefs/atd 의 TS port, 또는 community fork) | plain TS decoder/encoder | OCaml 측과 동일 도구 체인, atd 변경 즉시 TS 반영 | maturity 검증 필요, dashboard 의 zod-free 정책 호환 확인 |
| **B. atd → JSON Schema → 기존 schema-like 호환 codegen** | `atdgen -json-schema` (있다면) + custom transform | `schemas/sse.ts` 형식의 codegen | dashboard 의 SchemaLike 패턴 유지, 기존 ~310 LOC 직접 대체 | transform layer 1개 추가, JSON Schema 의 OCaml-specific coercion (e.g. json_string_opt) 표현 불가 |
| **C. Manual TS, atd 와 drift CI 로 묶음** | atd 파싱 OCaml tool + CI lint | manual TS 그대로, drift 시 CI fail | 가장 작은 의존성 변화, 기존 ~310 LOC 패턴 보존 | 새 event 추가 시 사람이 TS 도 같이 작성 (자동화 아님) |
| **D. atdgen-ts + zod 호환 wrapper layer** | atdgen-ts + thin zod-shaped adapter | TS decoder + SchemaLike 호환 wrapper | dashboard 코드 변경 최소화 | 두 codegen pipeline 운영 |

### 옵션 선호도 (현 시점, 사용자 결정 대기)

가장 **PR-1 의 byte-equal 정신** 과 호환되는 옵션은 **A 또는 B**:
- A 는 *동일한 atd contract* 가 양쪽 codegen 의 source. drift 자체가 불가능.
- B 는 *JSON Schema 라는 industry 표준 intermediate* 를 거침. atd 가 OCaml-specific 표현 (e.g. `json_string_opt` empty→null coercion) 을 갖고 있는 한 *완전* 변환 불가 → A 보다 손실 큼.

C 는 *workaround signature 7* (같은 typo N 사이트 N번 fix) 의 잠재 트리거. 새 event 마다 사람이 OCaml + TS 둘 다 작성하는 부담은 N=16 → 32 으로 늘어남.

D 는 운영 비용 큼 (2 pipeline) — 단기 *transition* 으로만 의미.

**잠정 권장: 옵션 A (atdgen-ts)**, 단 maturity 검증 (PR-1 PoC 와 동일 패턴: 1 event 로 round-trip 검증 → 통과 시 16 event 확장) 후 진입.

## 4. Sub-PR sequencing (Wave 2 = TS SSOT + golden replay + CLI emitter)

| PR | 산출물 | 변경 site | 추정 LOC |
|---|---|---|---|
| **A0.2-PR-0** (이 plan) | docs/rfc/0004-phase-a0-2-implementation-plan.md | docs only | ~250 |
| **A0.2-PR-1** | atdgen-ts (또는 선택 옵션) PoC — agent_started 1 event 만 TS decoder 생성, dashboard 의 schemas/sse.ts 와 *공존* (replace 아님) | `dashboard/src/schemas/sse_event_generated.ts` 신규, build script | ~200 |
| **A0.2-PR-2** | PR-1 PoC 가 dashboard 의 SSEEventStream parse 경로에서 *옵션 적용 가능* 확인. Feature flag 로 gating. | `dashboard/src/sse-store.ts` (1 conditional branch) | ~100 |
| **A0.2-PR-3** | 16 event 전체 codegen, manual schemas/sse.ts 와 *parallel run* | `dashboard/src/schemas/sse_event_generated.ts` 확장 | ~400 |
| **A0.2-PR-4** | Golden replay 도구 (`scripts/sse-replay/`) — production SSE log → atd parse → drift detector | OCaml CLI 신규 | ~300 |
| **A0.2-PR-5** | CLI emitter (`scripts/sse-sample-event.exe`) — `.atd` SSOT → sample JSON 생성 (test fixture / dev debugging) | OCaml CLI 신규 | ~150 |
| **A0.2-PR-6** | Manual `schemas/sse.ts` deprecate (codegen 으로 완전 대체), legacy 박멸 | dashboard 정리 | ~-500 (net 감소) |

각 PR 의 완료 기준 (Phase A0.1 패턴 계승):
- `dune build @check` + dashboard `tsc --noEmit` PASS
- A0.2-PR-3 까지: byte-equal — 동일 입력에 대해 manual schema 와 generated schema 의 parse 결과 deep-equal
- A0.2-PR-4: replay 결과 0 drift (production log subset 으로)
- A0.2-PR-6: manual schema 제거 후 IDE/runtime 동작 unchanged (smoke test)

## 5. Byte-equal protocol (Phase A0.1 계승)

마이그레이션 안전성의 핵심. 각 PR 에서:

1. Pre-migration baseline: 현재 `schemas/sse.ts` 의 parse 결과
2. Post-migration: codegen 의 parse 결과
3. 같은 입력 JSON (PR-A0.2-PR-5 의 CLI emitter 가 생성한 sample fixture) 에 대해 deep-equal 검증
4. 차이 발견 시: PR close + risk RFC 작성 후 재시작

PR-A0.2-PR-1 의 첫 commit = `agent_started` 1 event 로 round-trip 검증 (atd → codegen → TS decoder → JSON parse → deep-equal vs manual schema parse). 통과 시 나머지 15 event 확장.

## 6. Risk / mitigation

| Risk | Mitigation |
|---|---|
| atdgen-ts maturity 부족 (예: long-tail bug, recent commit 없음) | PR-1 PoC 단계에서 *blocker* 로 판정 가능. fail 시 옵션 B 또는 C 로 fallback (이 plan 의 §3 옵션 평가 재실행) |
| dashboard 의 zod-free 정책 위반 | atdgen-ts 가 generic schema runtime 의존성 끌어오는지 PR-1 PoC 에서 측정. `package.json` diff 가 zod / valibot / superstruct 등 신규 dep 없는지 확인 |
| OCaml-specific coercion (e.g. `json_string_opt` empty→null) 의 TS 측 재현 | OCaml 측이 emit 한 JSON 은 이미 null 로 정규화되어 있음 (Sse_event.json_string_opt 이 wrap 시점에 변환). TS decoder 는 nullable field 만 알면 됨. **atd 의 nullable annotation 으로 표현 가능 — 별도 coercion 불필요** |
| Manual schema 와 generated 의 parallel run 비용 | A0.2-PR-2 에서 feature flag 로 gating, 기본 OFF. A0.2-PR-6 에서 manual 박멸. transitional 비용 단기 |
| Production SSE log 접근 (PR-4) | `.masc/oas-events/` 의 dated_jsonl 이 local replay source. cloud production log 는 별 RFC 필요. PR-4 는 local 만 |

## 7. Open questions (사용자 결정 대기)

| 번호 | 질문 | 옵션 |
|---|---|---|
| 1 | TS codegen pipeline 선택 | (a) atdgen-ts / (b) atd→JSON Schema→custom transform / (c) Manual + drift CI / (d) atdgen-ts + zod adapter |
| 2 | PR-1 진입 시점 | (a) 이 plan PR 머지 직후 / (b) atdgen-ts maturity research 완료 후 |
| 3 | golden replay 의 source | (a) local `.masc/oas-events/` 만 / (b) production log subset 도 포함 (별 RFC) |
| 4 | CLI emitter 의 distribution | (a) `_build/default/.../sse-sample-event.exe` 내부 도구 / (b) opam package 로 release |

각 항목 사용자 합의 후 PR-1 진입.

## 8. Phase A0.1 dividend 의 재사용

다음 자산이 Phase A0.2 에서 그대로 활용 가능:

- **`lib/sse_event/sse_event.atd` 자체** — SSOT. Phase A0.2 의 모든 PR 의 source.
- **`test/sse_event/test_sse_event.ml` 의 19 byte-equal case** — OCaml 측 emission 의 wire format 고정. TS codegen 의 expected output 도 같은 wire format 이어야 byte-equal.
- **Inline replica 패턴** (`baseline_wrap_event` 등) — 향후 TS decoder 의 *역방향* (TS decode → OCaml-equivalent record) verification 에 mirror 적용 가능.

## 9. 다음 단계

1. 본 plan PR (`docs/rfc-0004-phase-a0-2-plan`) Draft 로 push
2. §7 open question 사용자 결정 대기 (특히 #1, #2)
3. 결정 후 PR-1 진입 — atdgen-ts (또는 선택 도구) maturity PoC

---

**Phase A0.1 ↔ A0.2 의 본질적 차이**: A0.1 은 OCaml 내부의 boundary 정리 (cascade emitter ↔ leaf event lib). A0.2 는 *cross-language boundary* (OCaml ↔ TypeScript). 도구 체인 선택의 risk 가 A0.1 보다 큼. Plan 단계에서 충분한 옵션 평가가 PR cadence 안전성을 좌우.
