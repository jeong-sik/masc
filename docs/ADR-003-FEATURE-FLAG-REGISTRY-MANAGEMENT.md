---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/config/feature_flag_registry.ml
---

# ADR-003: Feature Flag Registry Management - 중복과 불일치 방지 전략

**Status**: Accepted
**Date**: 2026-03-30
**Reviewers**: Codex, Human

---

## Context

MASC-MCP는 176개 이상의 환경변수 설정을 사용하며, boolean feature flag는 `lib/config/feature_flag_registry.ml`에 중앙 집중식으로 관리된다. 최근 PR #3793에서 `MASC_KEEPER_WORK_AS_HEARTBEAT` 플래그가 registry에 3번 중복 등록되는 문제가 발견되었다 (lines 95, 130, 140).

### 문제의 근본 원인

1. **Concurrent Feature Branches**: 여러 개발자가 독립적으로 같은 기능에 대한 플래그를 추가
2. **Git Merge의 한계**: Git은 구조적 중복(같은 값의 다른 위치 삽입)을 감지하지 못함
3. **리스트 기반 Registry**: Registry가 순서 있는 리스트로 구현되어 hash-key 기반 중복 검사 불가
4. **불완전한 CI 검증**: 기존 `check-feature-flag-consistency.sh`는 서로 다른 default를 가진 중복만 감지

### 발견된 추가 패턴

registry.ml 분석 결과:
- 176개 env 변수 getter가 config 모듈에 분산
- Feature flag lifecycle tracking (Active, Deprecated, Experimental)
- 일부 config getter는 registry에 미등록 (coverage gap)
- 설정값 변경 시 registry 동기화 누락 가능성

---

## Decision

### 1. Feature Flag Registry는 단일 진실 공급원(SSOT)이다

**원칙**:
- 모든 `MASC_*` boolean flag는 `Feature_flag_registry.all_flags`에 등록해야 함
- `env_name` 필드는 전역 고유해야 함 (duplicate 금지)
- Registry 외부에서 임의로 `get_bool` 호출 금지

**검증**:
- CI가 `check-feature-flag-consistency.sh` 실행
- duplicate env_name 감지 로직 추가 필요
- registry와 실제 usage 간 coverage check 필수

### 2. Config 변경은 Registry Update를 동반한다

**Workflow**:
```ocaml
(* 1단계: Feature_flag_registry에 등록 *)
{
  env_name = "MASC_NEW_FEATURE_ENABLED";
  default_value = false;
  lifecycle = Experimental;
  category = Runtime;
  since = "2.163.0";
  description = "Enable new experimental feature X";
}

(* 2단계: env_config_*.ml에서 getter 정의 *)
let get_new_feature_enabled () =
  Env_config_core.get_bool "MASC_NEW_FEATURE_ENABLED" false
```

**반드시 동시에**:
- Registry entry 추가
- Config module getter 추가
- 두 곳의 default 값 일치 확인
- Lifecycle 상태 명시

### 3. Concurrent Merge는 Semantic Validation이 필요하다

**현재 한계**:
- Git merge는 textual conflict만 감지
- 같은 env_name을 다른 위치에 추가하면 merge conflict 없이 통과
- 런타임에야 중복 발견 (또는 CI lint가 잡아야 함)

**개선 전략**:
- **Pre-commit hook**: registry 파일 변경 시 자동으로 duplicate check
- **CI lint 강화**: env_name uniqueness 검증
- **Registry 구조 개선 검토**: record type으로 컴파일 타임 uniqueness 강제 (Future)

### 4. Lifecycle Tracking은 Deprecation Workflow를 강제한다

**Flag Lifecycle States**:
| State | 의미 | 행동 규칙 |
|-------|------|----------|
| Experimental | 실험 중, 기본 off | 언제든 제거 가능 |
| Active | 프로덕션 사용 중 | breaking change 주의 |
| Deprecated | 단계적 폐기 예정 | 버전 N에서 deprecated, N+2에서 제거 |

**규칙**:
- Experimental → Active 전환 시 충분한 테스트 필요
- Active flag를 바로 제거 금지 (먼저 Deprecated로 전환)
- Deprecated flag는 최소 2 minor version 유지 후 제거

---

## Consequences

### 긍정적

1. **중복 방지**: env_name uniqueness가 명확한 규칙이 됨
2. **추적 가능성**: registry가 모든 flag의 lifecycle 이력 보존
3. **CI 검증**: 자동화된 consistency check로 인적 오류 감소
4. **문서화**: registry entry가 flag의 목적과 default를 명시

### 부정적

1. **추가 작업**: flag 추가 시 registry 등록 step 필수
2. **Merge conflict 증가**: registry 파일이 hot spot이 되어 merge conflict 빈발 가능
3. **Migration 비용**: 기존 미등록 flag들을 retroactive하게 등록해야 함
4. **구조적 한계**: 리스트 기반 registry는 여전히 runtime check에 의존

### 미해결 과제

1. **Registry 구조 개선**: 리스트 → hash map 또는 type-level uniqueness로 전환?
2. **Coverage 완전성**: 모든 env 변수를 registry에 등록할 것인가? (176개)
3. **동적 flag 추가**: runtime에 flag 추가가 필요한 경우는?
4. **Multi-module Config**: config가 여러 모듈에 분산된 현 구조를 유지할 것인가?

---

## Implementation Checklist

### 즉시 적용 (Done)
- [x] PR #3793: 중복된 WORK_AS_HEARTBEAT 제거

### 단기 (v2.163.0 목표)
- [ ] CI lint 강화: env_name duplicate check 추가
- [ ] Pre-commit hook 추가: registry 변경 시 자동 validation
- [ ] Coverage report: registry 미등록 flag 목록 자동 생성

### 중기 (v2.164.0 목표)
- [ ] Registry migration: 기존 미등록 flag들 일괄 등록
- [ ] Lifecycle policy 문서화: Experimental → Active → Deprecated 전환 기준 명시
- [ ] Test coverage: registry entry와 실제 usage 일치 검증 테스트

### 장기 (Future)
- [ ] Registry 구조 개선: type-level uniqueness 또는 GADT 사용 검토
- [ ] Config unification: 분산된 env_config_* 모듈 통합 방안 검토

---

## Best Practices

### ✅ DO

```ocaml
(* 1. Registry에 먼저 등록 *)
let flag = {
  env_name = "MASC_KEEPER_ADAPTIVE_SCHEDULING";
  default_value = false;
  lifecycle = Experimental;
  category = Keeper;
  since = "2.163.0";
  description = "Enable adaptive keeper scheduling based on load";
}

(* 2. Config module에서 참조 *)
let get_adaptive_scheduling () =
  Env_config_core.get_bool "MASC_KEEPER_ADAPTIVE_SCHEDULING" false
  (* ⚠️ default must match registry entry! *)
```

### ❌ DON'T

```ocaml
(* ❌ Registry 없이 직접 get_bool 사용 *)
let get_my_feature () =
  Env_config_core.get_bool "MASC_MY_FEATURE" true  (* 어디에도 문서화 안 됨 *)

(* ❌ Registry와 다른 default 사용 *)
(* Registry: default = false, Config: default = true ← inconsistent! *)

(* ❌ Concurrent merge 후 duplicate 방치 *)
(* same env_name을 여러 곳에 등록 ← CI가 잡아야 함 *)
```

### 병합 전 Checklist

PR author:
- [ ] registry 변경이 있는가?
- [ ] env_name이 기존 registry와 중복되지 않는가?
- [ ] config module의 default가 registry entry와 일치하는가?
- [ ] lifecycle 상태가 올바른가? (Experimental for new flags)
- [ ] since version이 정확한가?

Reviewer:
- [ ] registry entry가 명확하고 이해 가능한가?
- [ ] category가 올바른가?
- [ ] 같은 feature에 대한 기존 flag가 있는가? (rename인가 new인가)
- [ ] CI lint가 통과했는가?

---

## References

- PR #3793: fix(config): remove duplicate WORK_AS_HEARTBEAT entries
- `lib/config/feature_flag_registry.ml` - Registry SSOT
- `lib/config/env_config_core.ml` - Base config getters
- `scripts/check-feature-flag-consistency.sh` - CI consistency check
- `docs/COMMON-PITFALLS.md` Section 8: Feature Flag Lifecycle Management

---

## Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-03-30 | Initial ADR, duplicate WORK_AS_HEARTBEAT 분석 반영 | Codex |
