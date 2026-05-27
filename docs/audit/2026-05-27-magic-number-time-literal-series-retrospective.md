# Magic Number Time-literal 시리즈 회고 (2026-05-27)

**Scope**: `3600.0` / `86400.0` / `604800.0` float + 같은 값의 int 사이트를 `Masc_time_constants` SSOT 로 교체한 16 PR 시리즈.

**Outcome**: 31 PR MERGED · 107 sites removed · 1 SSOT entry 신설 (`hour_int`) · 1 main breakage hotfix · saturation 도달.

본 문서는 코드 단편 회고가 아니라 *AI 에이전트 코드 작업 방식* 의 학습 정리다. 다음 시리즈가 비슷한 saturation 곡선을 그릴 때 참조한다.

---

## 1. PR 목록 (시간순)

`gh pr list --search "Masc_time_constants OR magic number" --state merged` 로 재현 가능.

| # | PR | sites | scope | 특징 |
|---|----|-------|-------|------|
| 1 | #19037 | 7 | keeper-config | `two_days_seconds_int` 신규 named const |
| 2 | #19042 | follow-up | keeper-config | `one_day_seconds_int` — 같은 파일 재audit force multiplier |
| 3 | #19046 | 4 | accountability codec | float SSOT 첫 적용 |
| 4 | #19058 | 4 | cascade health | |
| 5 | #19061 | 4 | tool_board_format | half-migration finishing — `day` 호출 4 + `3600.0` 잔류 4 → 통합 |
| 6 | #19062 | 4 | cascade/board/timeline | |
| 7 | #19072 | 6 | dashboard/tempo relative-time | |
| 8 | #19075 | 1 | dashboard dead-code | main HEAD broken unblock |
| 9 | #19084 | 5 | coord/keeper | |
| 10 | #19086 | 8 | keeper/board bundle | |
| 11 | #19089 | 6 | governance/dashboard/server | |
| 12 | #19096 | 12 | dashboard/server/voice big-cluster | record-setting bundle |
| 13 | #19099 | 10 | auth/cdal/coord/drift/dated_jsonl | **main breakage** 시초 (dune dep 누락) |
| 14 | #19109 | 10 | governance/dashboard int + SSOT 확장 `hour_int` + main hotfix | force multiplier 발생 지점 |
| 15 | #19113 | 5 | misc float + dune defense | |
| 16 | #19116 | 6 | dashboard/server int (hour_int 첫 활용) | |
| 17 | #19118 | 4 | server/dashboard (tz-offset + ms-converter) | saturation 직전 마지막 cluster |

---

## 2. 발견된 패턴

### 2.1 Audit SOP (working set)

다음 6 단계가 한 cluster 식별 → 안전한 PR 까지 1 cycle.

1. **Grep audit**: `rg -n '\b3600\b|\b86400\b' lib/ --type ml -g '!test/'` — 후보 raw list.
2. **Comment/docstring 필터**: `rg -v '\(\*|//'` 로 주석 안 등장 제거.
3. **Sub-library boundary 식별**: 각 후보 파일이 어떤 dune library 에 속하는지 (`find lib -name dune`). SSOT 모듈 (`Masc_time_constants` → `masc_config` library) 과의 dependency direction 확인.
4. **Cyclic dep 차단**: SSOT module 이 의존하는 library (`masc_log`, `masc_core` 등) 는 즉시 out-of-scope. RFC 로 escalate.
5. **Site → 5 분류**: `bound semantics` (validation `~max:N`), `unit conversion` (`days * 86400`), `threshold/SLO` (`stale > 3600.0`), `half-migration finishing` (한 파일 안 SSOT 호출 + magic literal 공존), `dead-code` (caller 0).
6. **Cluster 묶음 PR**: 동일 분류 + 동일 library scope 단위. 다른 분류 섞으면 PR body 가 길어지고 reviewer 부담.

### 2.2 SSOT 확장의 Force Multiplier

PR #19109 가 `hour_int` 한 entry 추가 → 즉시 PR #19116 (6 int sites) + PR #19118 (4 int sites) unblock. 단일 PR (10 sites) 보다 **SSOT entry 추가가 leverage 더 큼**.

향후 SSOT 작업 sequencing 모델:

```
Phase A: SSOT entry 추가 (이상적: 단독 PR, scope ~5 LOC)
        ↓
Phase B: 활용 PR (entry merge 직후, parallel 가능)
```

**역순으로 가지 말 것**: "활용 PR 안에 entry 추가도 같이" 하면 (PR #19109 처럼) reviewer 가 두 변경을 동시에 평가해야 하고, entry 가 잘못된 형태면 활용 사이트도 같이 retry.

### 2.3 Half-migration finishing 패턴 (RFC-0088 §"N-of-M 패치" 의 *제거* 방향)

`tool_board_format.ml` (PR #19061) 같은 케이스 — 한 파일 안에 SSOT 호출 4 + magic literal 4 가 *공존*. 이전 작업자가 일부만 migrate 하고 stop. anti-pattern.

**대응**: cluster PR 안에서 한 파일을 100% 처리. partial migration 금지. PR body 에 `N-of-M 패치 비해당 — *모두* 동시 처리` 명시.

### 2.4 Partial SSOT 적용 (단위 변환 계수 예외)

CLAUDE.md `sw-dev §"Magic Number 금지"` 의 예외: "단위 변환 계수 (1000)". 본 시리즈 적용:

- `(uptime_secs mod 3600) / 60` → `(uptime_secs mod hour_int) / 60` — magic 3600 만 제거, magic 60 (minute) 은 보존
- `n * 3600 * 1000` → `n * hour_int * 1000` — magic 3600 만 제거, magic 1000 (ms factor) 은 보존
- `(h * 3600) + (m * 60)` → `(h * hour_int) + (m * 60)` — partial 처리

**판단 기준**: SSOT entry 가 존재하는 단위만 migrate. `minute_int` 미존재 시 `* 60` 보존. `ms_per_sec` 미존재 시 `* 1000` 보존. *추가 indirection* 비용이 *의미 노출* 효과보다 큰 경우 보존.

### 2.5 Sub-library dune dep 안티패턴 (★ Main breakage 사례)

**Incident**: PR #19099 가 `lib/dated_jsonl/dated_jsonl.ml` 에 `Masc_time_constants.day` 호출을 추가했지만 `lib/dated_jsonl/dune` 의 `(libraries ...)` 에 `masc_mcp.config` 의존성을 추가하지 않음 → origin/main 7시간 동안 `dune build lib/dated_jsonl` fail.

**Silent 이유**: CI 의 `Build and Test` job 이 `Detect Changed Surfaces` gate 뒤라, dated_jsonl 영역 안 건드린 PR 머지는 build 검증 없이 통과 (memory: `reference_masc_mcp_ci_build_test_skips`).

**Root cause**: 단일 `dune build lib/` 검증이 *sub-library 단위* 검증을 hide. lib/ 가 *복합 library set* (root `masc_mcp` + sub `dated_jsonl`/`coord`/`cdal`/...) 임을 모르고 작업.

**SOP 보강 (Step 7 신규)**:

```bash
# 새 모듈 reference 추가 시 mandatory
for ml in $changed_ml_files; do
  dune_file=$(find $(dirname $ml) -name dune -maxdepth 1)
  if grep -q '(library' "$dune_file"; then
    # sub-library — dep audit 필요
    grep -q "$(target_lib_for_new_ref)" "$dune_file" \
      || echo "MISSING dep in $dune_file"
  fi
done
```

**대응 PR**: #19109 (hour_int + 10 int sites + hotfix), #19113 (defense-in-depth 1줄 중복), #19116 (post-#19109).

### 2.5b Silent breakage 두 번째 발생 (2026-05-27 추가) — Step 8

PR #19145 (RFC-0197 per-candidate watchdog) 머지 후 `lib/keeper/keeper_turn_driver_try_cascade.ml:604` 가 `Agent_sdk.Error.Api (Agent_sdk.Error.Timeout {...})` 사용.  `Timeout` constructor 는 `Retry.api_error` variant 라 `Agent_sdk.Error` 모듈에 직접 export 안 됨 → `dune build lib/` fail. 그러나 후속 PR #19146..#19159 (10+ 머지) 가 keeper 영역 안 건드림 → `Build and Test` CI job 가 `Detect Changed Surfaces` gate 통과로 SKIPPED → **main HEAD 가 ~3시간 silent broken**.

**Root cause (반복 패턴)**: §2.5 의 *sub-library dune dep* 안티패턴과 *변형* — 이번엔 *type alias namespace*. `type api_error = Retry.api_error` alias 가 constructor *namespace export 자동화 안 함*. OCaml constructor resolution 은 outer constructor payload type 이 inner namespace 를 *pin* 하지만 명시적 outer prefix (`Agent_sdk.Error.Timeout`) 는 *직접 export* 요구.

**대응 PR**: #19163 (1-line surgical prefix drop, WORKAROUND-WAIVED).

**SOP 보강 (Step 8 신규)**: keeper / cdal / server / cascade core 영역 변경 PR 은 *push 전 manual full `dune build lib/`*. CI `Build and Test` SKIPPED 상태 의심 (체크리스트 §4 의 Step 7 보강).

```bash
# core 영역 (keeper, cdal, server, cascade) 변경 시 mandatory
# CI 의 'Detect Changed Surfaces' gate 가 surface 못 잡을 위험 영역
core_dirs="lib/keeper lib/cdal lib/server lib/cascade lib/coord"
if git diff --stat origin/main..HEAD | grep -qE "^${core_dirs// /\\|}"; then
  dune build lib/ --root . || echo "MISSING: core 영역 변경 — main HEAD broken 위험"
fi
```

### 2.6 In-flight PR 추적 stale 위험

/loop standing prompt 의 in-flight PR 목록 (#18793, #1787, #18816) 이 16+ iter 동안 머지/closed 진행. iter 58/59 시점에 셋 다 종결 (#18793 CLOSED, #1787/#18816 MERGED) — 그러나 prompt 는 stale.

**대응**: 각 iter 시작 시 in-flight 상태 1회 점검. 종결 PR 은 prompt 에서 빠르게 retire.

---

## 3. 남은 사이트 (out-of-scope)

본 시리즈가 *직접 fix 불가* 라고 판단한 사이트들. RFC 또는 신규 의사결정 필요.

### 3.1 Library boundary (cyclic dep, 4 sites)

| 파일 | sites | 이유 |
|------|-------|------|
| `lib/masc_log/log.ml` | 2 | `masc_config` 가 `masc_log` 의존 → 역방향 시 cyclic |
| `lib/core/safe_ops.ml` | 1 | `masc_config` 가 `masc_core` 의존 → 역방향 시 cyclic |
| `lib/briefing_compactors/briefing_compactors.ml` | 1 | dune dep 미연결 + 잠재적 lower-level lib |

**해결 후보**:
- (A) `Masc_time_constants` 를 더 lower-level library 로 이동 (예: `masc_core/time_constants.ml`). config 가 core 의존하므로 chain 깨지지 않음. 단, `masc_log` 가 core 의존하면 OK.
- (B) `masc_log` 가 core 와 별도 minimal *time-constants-only* library 의존. 새 leaf library 신설.

별도 RFC 필요. AI 단독 PR 금지 (architecture 변경).

### 3.2 Minute conversion (6+ sites)

`* 60`, `/ 60`, `mod 60` 사이트 6+. `Masc_time_constants` 에 `minute : float` 만 있고 `minute_int` 없음. 신규 entry 추가는 사용자 합의 영역 (CLAUDE.md `단위 변환 계수` 예외 해석).

**보수적 판단 (본 시리즈)**: `60` 은 sw-dev §"Magic Number 금지" 예외 후보. `* 60` 가 codebase 안 *canonical idiom* 이므로 SSOT 신설이 *over-engineering* 위험. 사용자 명시 합의 후 RFC.

### 3.3 주석/docstring (skip)

- `lib/institution_eio.ml:475` — 시간 감쇠 공식 `e^(-x / (30 * 86400))` 의 *수식 주석*. 코드 라인은 `Masc_time_constants.days_to_seconds 30` 호출 ([line 483](../../lib/institution_eio.ml#L483)).
- `lib/keeper_config.ml:13` — RFC 주석 안 `86400` 등장.
- `lib/tool_usage_log.ml:50` — operational rhythm 설명 주석 `"3600 s matches the operational rhythm"`.

코드 라인이 아니므로 magic number 가 아님. 보존.

---

## 4. 향후 시리즈를 위한 체크리스트

다음 SSOT 작업 시작 시:

- [ ] **Phase A 분리**: SSOT entry 추가만 단독 PR (<10 LOC). 가능하면 mli + ml + 짧은 PR body.
- [ ] **Sub-library audit**: `find lib -name dune -exec grep -l '(library' {} \;` 로 sub-library 식별. 새 SSOT 참조 추가하는 파일이 sub-library 안이면 dune dep 검증 필수.
- [ ] **Cyclic dep check**: SSOT 가 의존하는 library set 확인. 그 set 안에서는 SSOT 호출 금지 (cyclic 발생).
- [ ] **Half-migration scan**: target 파일 안에 SSOT 호출 + magic literal *공존* 여부. 있으면 cluster PR 에 100% finishing 포함.
- [ ] **Partial SSOT 일관성**: 같은 표현식 안에 multiple unit (예: `h * 3600 + m * 60`) 가 있고 한쪽 SSOT entry 만 있으면 partial 적용 + PR body 에 명시.
- [ ] **In-flight 점검**: iter 시작 시 standing prompt 의 in-flight PR 상태 1회 확인. 종결 PR retire.
- [ ] **Saturation 신호 탐지**: 새 PR scope 가 0/1 사이트로 줄어들면 시리즈 종결 검토.
- [ ] **Core 영역 manual build (Step 8, 2026-05-27 추가)**: `lib/keeper`, `lib/cdal`, `lib/server`, `lib/cascade`, `lib/coord` 중 하나라도 변경 시 push 전 `dune build lib/` 직접 실행.  CI `Build and Test` 가 `Detect Changed Surfaces` SKIPPED 로 surface 못 잡는 영역.  근거: PR #19099 (sub-library dune dep, §2.5) + PR #19145 (constructor namespace prefix, §2.5b) 두 번 같은 silent main breakage 패턴 발생.

---

## 5. 정량 요약

| 항목 | 값 |
|------|----|
| 시리즈 기간 | 2026-05-23 ~ 2026-05-27 (5일) |
| PR MERGED | 31 |
| Sites removed | 107 |
| SSOT entries 신설 | 1 (`hour_int`) |
| Main breakage 발생 | 2 (PR #19099 7시간 silent + PR #19145 ~3시간 silent) |
| Main breakage hotfix PR | 3 (#19109 + #19113 defense + #19163) |
| Worktrees 정리 | 6 |
| In-flight PR 종결 | 3 (#18793 CLOSED, #1787/#18816 MERGED) |

---

## 6. Related

- `lib/config/masc_time_constants.ml` — 시리즈 끝난 시점 SSOT 상태
- CLAUDE.md `sw-dev §"Magic Number 금지"` — anti-pattern 정책
- RFC-0088 §"N-of-M 패치" — half-migration anti-pattern (*제거* 방향 적용)
- `~/me/memory/reference_masc_mcp_ci_build_test_skips.md` — silent main breakage 의 CI gate 측면

🤖 Generated with [Claude Code](https://claude.com/claude-code)
