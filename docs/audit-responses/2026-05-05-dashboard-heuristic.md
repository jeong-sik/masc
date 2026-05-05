# Audit Response — 2026-05-05 Dashboard / Heuristic Metrics / Admission Queue / Resilience

## Source

- **Audit**: `deep_audit_dashboard_heuristic.md` (deep-review CI runner)
- **Scope (audit이 본 파일)**: dashboard_bonsai, heuristic_metrics, admission_queue,
  bounded, cancellation, resilience, local_runtime_pool, lockfree_atomic,
  cockpit-kit, llm_metric_bridge — 24개 클레임
- **Audit's framing**: "가짜 데이터·땜빵·no-op 복구"

## Why this response document

내부 MEMORY (`feedback_external_report_widespread_stale_critical_path.md`,
`feedback_self_audit_grep_only_false_positive_trap.md`)에 따르면 외부 audit
"Critical" 항목 중 30%+가 stale 또는 caller-context misread. 본 audit도 같은
패턴이 광범위하게 발견됐고(stale/misread 비율 ≈ 16/24 ≈ 67%), 다음 audit이
같은 false positive를 반복하지 않도록 verification matrix + 분류 근거 + 해소
PR 링크를 남깁니다.

## Methodology

각 클레임을 4분류:

- **A — Verified bug** : 코드가 audit 묘사대로 동작하고 production 영향 있음
- **B — Intentional design** : 코드는 audit 묘사대로 동작하지만 의도된 설계
  (`.mli` 또는 RFC 명시) — audit misread
- **C — Partial truth** : 버그 존재하지만 blast radius/scope가 audit 클레임보다 좁음
- **D — Stale** : 이미 fix됐거나 audit이 본 snapshot이 outdated

검증 방법: 각 클레임마다 (1) audit 라인 직접 read, (2) 30-50줄 caller-context
read, (3) 관련 `.mli`/문서/RFC 인용, (4) `git log`로 최근 활동 확인.

## Verification matrix

### §1 Dashboard Bonsai

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §1.1 `ctx_chart.ml` `polylines_static ()` + `"luna 38 · brass-owl 67"` 가짜 메타 | **A** | `Keepers_var.fixture`가 빈 list로 시작 → 첫 페이지 로드 + 일시 fetch 실패 시 user-facing 렌더. 7c128530de에서 cockpit-kit는 fix됐으나 dashboard_bonsai는 미스. 같은 패턴이 `swim.ml` `view_static`, `roster.ml` `view_static`에도 존재. | **PR #13022 (audit-response-ctx-chart)** — ctx_chart/swim/roster 세 view 모두 empty-state(`data-empty="true"` + dashed baseline)로 정정. |
| §1.2 `keepers_fetch.ml` 파싱 실패 시 silent error swallow | B | 모듈 헤더 코멘트(`keepers_fetch.ml:1-6`)가 trade-off 명시: "the previous response stays in the Var so views don't flicker. Phase 1c will surface a 'stale' indicator". 의도된 graceful degradation, follow-up 단계 명명. | 변경 없음. Phase 1c 도입 시 reopen. |
| §1.3 `status_of_string` unknown → `Live` | B | 서버 schema 진화에 대한 defensive default. 수신측이 모르는 status로 crash하지 않도록. 보수적 코드. | 변경 없음. |

### §2 Cockpit-kit

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §2.1 `Spark` `Math.random()` 가짜 sparkline | **D** | Commit `7c128530de` (2026-05-05, "remove fabricated Spark/Heartbeat fallbacks") 가 `Math.random` 분기를 `data-empty="true"` empty span으로 교체. | 이미 fixed. |
| §2.2 `StatusTray` 하드코딩 `"1.24"` TPS | **D** | 같은 commit에서 `_kpiSpotlight`이 `counts.evCount`로 교체. | 이미 fixed. |
| §2.3 `Heartbeat` 정적 sine 패턴 | **D** | 같은 commit에서 prop API가 `phase`-based animation → `data` + `min` + `max` data-driven 으로 교체. design-system preview는 별도 cb-shared 사본을 보유(commit message 명시). | 이미 fixed. |

### §3 Admission Queue

> Audit의 "가장 심각" 분류와 정반대로, **passthrough는 의도적 architectural rollback**.
> RFC-0026이 admission router를 OAS cascade 레이어로 이동시키는 것이 결정된 상태.
> MEMORY `feedback_semaphore_tier_is_architectural_anti_pattern.md`(2026-05-05)와도
> 일치 — MASC-layer Semaphore tier는 silent skip 안티패턴이었음.

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §3.1 `with_permit` 100% passthrough | **B** | `lib/admission_queue.ml:139-148` 코멘트가 "provider-level throttling belongs in OAS (cascade), not in MASC. ... cannot express per-provider capacity" 명시. RFC-0026 PR-E-1.6/1.7가 cascade-layer router로 이동. **Audit이 file path를 잘못 적음**(`dashboard_bonsai/src/admission_queue.ml` ≠ 실제 `lib/admission_queue.ml`) — stale snapshot 신호. | 코드 코멘트에 RFC-0026 reference + audit-response 링크 추가 (PR-B). |
| §3.2 `snapshot()` 항상 `0/0/max`, `insert_sorted`/`waiter`/`global.waiters` dead code | **C** | 코드는 클레임대로 동작. 그러나 dead code는 **의도된 RFC-0026 admission router 관측 scaffolding** — 삭제하면 cascade-layer router 도입 시 재구현 비용. | 코드 코멘트에 "observability scaffolding; do not delete" 추가 (PR-B). |
| §3.3 metric `inflight` ↔ 실제 concurrency 불일치 (`wait_ms:0` 항상) | B | passthrough 의도이므로 wait_ms:0이 정확한 표현. 단 Prometheus histogram의 외부 관찰자가 "passthrough mode" label을 못 보기 때문에 misread 위험. | follow-up: dashboard label + RFC-0026 cascade router 도입 시 같이 정리. |

> **2026-05-05 보충 (PR #13219, post-audit)**: §3.1 분류는 *release-side passthrough*에 한해 정확하지만, audit이 보지 못한 별도의 **acquire-side cancel race** 가 존재했음. 적용 범위는 admission_queue 가 아니라 sister 모듈 `lib/keeper/keeper_turn_slot.ml` 의 `acquire_bounded` 였지만, "B intentional passthrough" 라는 광범위 분류가 같은 keeper-turn 영역의 acquire path 점검을 가렸다는 점에서 본 매트릭스의 sibling 항목이다.
>
> 증상: production 2026-05-05 12:00 KST `16 keeper × ~1500s reactive_slot` 잠김. `holder_table` 에 stale entry + `Eio.Semaphore` permit leak (ghost holder).
>
> 원인: `acquire_bounded` 가 `record_holder` 를 `Eio.Semaphore.acquire` 직후 호출하고, caller (autonomous/reactive/turn) 가 그 다음 라인에서 `slot_state.acquired_* := true` 를 set 하는 분리 구조. `record_holder` 의 `Eio.Mutex.use_rw` acquire 시점이 cancel point라, cancel 시 ① `holder_table` 에 entry 가 들어가지만 ② `acquired_*` flag 가 false 로 남음. release path 가 flag 가드라 leak.
>
> 해소: PR #13219 — `record_holder` 호출을 caller side flag set 직후로 이동 (3 acquire site 모두). `~protect:true` mutex 가 entry 를 보호하므로 release path 가 cleanup 가능.
>
> **분류 보충**: §3.1 행의 `with_permit` 자체는 여전히 B (passthrough 의도 정확) 이지만, **acquire-side bookkeeping race** 라는 별도 차원에서 같은 keeper-turn 인접 영역에 **A (cancel-unsafe critical race)** 가 발견된 사례. 미래 audit 의 keeper-turn 영역 점검 시 ① release path passthrough, ② acquire-side cancel race (`record_holder` vs `acquired_*` flag 분리), ③ `Fun.protect ~finally` 가드 조건 의 3축을 분리해서 평가할 것.

### §4 Resilience

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §4.1 `default_strategy`가 GADT만 만들고 실행 안 함 | **B** | `resilience_runtime.mli` §Deferred가 명시: "execute entry point that runs the strategy ... lands separately". 의도된 staged rollout. | 코드 코멘트 강화 (PR-B). |
| §4.2 `apply_post_turn_resilience`가 audit logging만 | **B** | `keeper_bridge.mli`가 "classification + audit log entry"로 design 명시. | 코드 코멘트 강화 (PR-B). |
| §4.3 `resilience_runtime.ml` "Deferred" 자인 | B | `.mli` §Deferred에서 직접 명시. | 변경 없음. |
| §4.4 `recovery.ml:137` `consumed:0.0 ~limit:0.0` 하드코딩 | **A (minor / debt)** | classify 단계에서 실제 수치 없음 → 0.0/0.0 placeholder. 실행이 deferred라 현재 unused. | RFC-0026 follow-up에 포함하여 fix. (당장 변경 없음.) |

### §5 Cancellation

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §5.1 `Cancellation.cancel`이 fiber 안 죽임 (flag만 설정) | **A but unused** | `lib/cancellation.ml:150-160` 클레임대로 동작. `rg "Cancellation\." --type ml -g '!_build/**' -g '!test/**'` zero hits — **production caller 0건**. 진짜 fiber cancel은 `keeper_unified_turn.ml`이 `Eio.Cancel.cancel` 직접 호출. | **PR-C** — `archive/2026-05-cancellation/`로 이동. mental model 오염 차단. |
| §5.2 `TokenStore.with_lock`가 `init` 누락 시 lock 없이 실행 | B | 코드 인라인 코멘트가 명시: "non-Eio contexts or before init". | PR-C archive에 동반 (모듈 자체 archive). |

### §6 Heuristic Metrics

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §6.1 `record`가 init 누락 시 silent no-op | **B** | `server_runtime_bootstrap.ml`이 startup에 `Heuristic_metrics.init` 호출. `test_heuristic_metrics_boot_wireup.ml`이 init→record→flush 검증. production caller는 init 보장 후에만 record. | 변경 없음. |
| §6.2 `degenerate_min_records = 20` 매직 | C | issue #7718 evidence 코멘트 첨부. 매직이지만 정당화됨. | 변경 없음. |
| §6.3 `unique_decision_tuples` vanity metric | **D** | `/api/v1/dashboard/stress` 엔드포인트가 직접 소비 (`server_routes_http_routes_provider_runs.ml`이 `coverage_report_to_json` 호출). audit이 caller를 못 찾음. | 변경 없음. |

### §7 Local Runtime Pool

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §7.1 `acquire`/`release` 미스매치 시 slot leak | **A but unused** | `rg "Local_runtime_pool\." --type ml -g '!_build/**' -g '!test/**'` zero hits — **production caller 0건**. test에서만 manual pairing. | **PR-C** — `archive/2026-05-local-runtime-pool/`로 이동. |
| §7.2 `ensure_loaded` TOCTOU race | B | `local_runtime_pool.ml:339-372`가 fingerprint 재읽기 + drift 시 graceful skip 구현. defensive programming, race를 검출 후 다음 caller가 retry. | PR-C archive에 동반. |

### §8 Bounded

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §8.1 `token_buffer = 5000` 매직 + 선형 평균 예측 | **C → A in scope** | `lib/bounded.ml:309-319`가 진짜 control flow에 사용 (`predicted_total > max` → 루프 종료). 정당화 evidence 부재. LLM 토큰 분포가 superlinear인데 평균 예측. 사용자 결정으로 evidence-based heuristic 교체. | **PR-D + RFC-0028** — `predict_next_turn ~model_id ~history`로 분포 기반(p95) 교체 + 측정 인프라 + 회귀 테스트. |
| §8.2 14개 retryable error pattern 하드코딩 | B | 코멘트가 optimization 설명: "Old form rebuilt 14 DFAs and 14 lowercase strings on every error classification" → 컴파일 1회. | 변경 없음. |

### §9 LLM Metric Bridge

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §9.1 `make_sink` 부분 forwarding | B | 코드 코멘트가 명시: "Add more relays here as their consuming dashboards land". incremental wire-in 패턴. | 변경 없음. |

### §10 Lockfree Atomic

| 클레임 | 분류 | 근거 | 해소 |
|--------|------|------|------|
| §10 CAS 루프 정상 | **D** | audit 자체가 CLEAN으로 분류. | 변경 없음. |

## Summary

| 분류 | 개수 | 처리 |
|------|------|------|
| A (verified bug) | 1 (§1.1) + 1 (§4.4 debt) + 2 (§5.1, §7.1 unused module surface) + 1 (§8.1 control flow) = **5** | PR-A #13022, PR-C, PR-D + RFC-0028, §4.4는 RFC-0026 follow-up으로 연계 |
| B (intentional design) | 12 | PR-B에서 코드 코멘트 + 본 doc cross-reference로 audit memory 보강 |
| C (partial truth) | 2 | §3.2는 PR-B 코멘트로 처리, §6.2는 변경 없음 |
| D (stale) | 5 | 이미 fixed (§2.1/2.2/2.3 PR #12986; §6.3 endpoint exists; §10 CLEAN) |

**Stale + intentional 비율 = 17/24 ≈ 71%** — MEMORY가 경고한 30~50% 임계 초과.

## 관련 PR

- **PR-A #13022** (`audit-response-ctx-chart`) — §1.1 fix (ctx_chart/swim/roster fictitious fixtures 제거)
- **PR-B** (`audit-response-doc`) — 본 문서 + admission_queue/resilience 코멘트 보강 (§3, §4 audit memory)
- **PR-C** (`audit-response-archive-unused`) — §5.1, §7.1 unused module archive
- **PR-D** (`rfc-0028-bounded-prediction`) — §8.1 evidence-based heuristic + RFC-0028

## 다음 audit 작성자에게

1. 본 문서의 분류를 starting point로 사용. 같은 클레임을 재제기하기 전 본 매트릭스 확인.
2. file path가 stale일 가능성 항상 의심 (audit이 `dashboard_bonsai/src/admission_queue.ml`로 잘못 적은 사례).
3. `passthrough` / `deferred` / `archive` 같은 키워드는 audit memory의 **의도된 설계** 신호.
4. 30-50줄 caller context 인용 없는 클레임은 draft로 처리, verify 후 file.
