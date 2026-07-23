---
rfc: "dead-tracked-file-accumulation-gate"
title: "Dead tracked-file 누적 방지: baseline-free 게이트 (RFC-0151 함정 회피)"
status: Draft
created: 2026-07-24
updated: 2026-07-24
author: vincent
supersedes: []
superseded_by: null
related: ["0151", "0249"]
implementation_prs: []
---

# RFC: Dead tracked-file 누적 방지 — baseline-free 게이트 (RFC-0151 함정 회피)

**Status**: Draft — 오너 검토 대기
**Date**: 2026-07-24
**연관**: RFC-0151 (Withdrawn, 본 RFC의 기각 선례) · RFC-0249 (개별 dead 점적 제거, complement) · PR jeong-sik/masc#25637 (2026-07-23 T1 dead-file 삭제)
**Evidence**: 2026-07-23 dead-file sweep (4-영역 병렬 검증 + 독립 교차검증 → 37 dead / 2 제외) 및 2026-07-24 갭 측정 (`audit-dead-surface.py --modules` = 0)
**Blocks**: dead-file 누적 방지 인프라 (lint 신규 + CI 연결)
**Non-blocking**: PR #25637 (T1 18개 삭제)는 본 RFC와 무관하게 독립 진행

## 1. Summary

masc의 git-tracked dead file(빌드/런타임/참조에 기여하지 않지만 커밋된 파일)이 반복적으로 누적되어 수동 sweep에 의존하고 있다(2026-07-21 dead-surface 감사, 2026-07-23 T1 정리 PR #25637). 본 RFC는 누적을 막는 **CI 게이트**를 설계하되, **RFC-0151이 입증한 monotone ratchet의 함정(baseline drift → 협업 세금)을 명시적으로 회피**한다.

## 2. Motivation (문제)

2026-07-23 sweep에서 4개 영역(OCaml/TS/문서/스크립트) 병렬 검증 + 독립 교차검증으로 37개 dead file을 식별했다. 18개(T1)는 PR #25637로 삭제 중. 이런 수동 sweep은:

1. **땜방이다.** 발각은 하되 누적 원인을 막지 않는다. MANIFEST "워크어라운드 거부 기준"이 말하는 symptom 억제 패턴에 해당한다.
2. **비결정적 비용이 크다.** "이 일회성 스크립트를 살릴까"는 인간 판단이고, 매번 워크플로우 에이전트 + 교차검증을 돌려야 한다.
3. **반복된다.** 07-21 감사에 이어 07-23 재감사. 코드-삭제-연동 프로세스가 없으면 계속 쌓인다.

## 3. 근본 원인 (3가지)

| 원인 | 예 | 현재 차단 |
|------|-----|-----------|
| **(R1) 코드 삭제 시 연관 파일 삭제 누락** | `masc_handover*` 코드는 삭제했으나 `docs/CELLULAR-AGENT.md`는 남음; `create_discussion` 삭제 후 policy 문서 남음 | 없음 (PR 리뷰에만 의존) |
| **(R2) 빌드 그래프 밖 파일이 참조 검증 없이 커밋** | `docs/spec/gate_protocol_sketch.ml`, `fixtures/pacing_*.ml` (dune이 모름) | 없음 |
| **(R3) CI가 "존재하지만 미사용"을 안 잡음** | caller-0 스크립트, import-0 TS, orphan 문서 | 없음 — "존재하는 게 빌드되나"만 검증 |

## 4. 갭 측정 (2026-07-24, 결정론적)

| 카테고리 | 현 규모 | 탐지 도구 | CI 게이트 |
|----------|--------|-----------|-----------|
| OCaml lib/ 빌드 module dead | **0 (깨끗)** | `audit-dead-surface.py` ✓ 정확 (token + compiler 기반) | **수동** |
| docs/fixtures/ 빌드밖 .ml dead | PR #25637로 3개 삭제 중 | 도구 스코프 밖 | 없음 |
| withdrawn/Retired 문서 | **92개** | 없음 | 없음 |
| caller-0 스크립트 (CI/Makefile 기준) | **104+개** | 없음 | 없음 |
| TS unused (dashboard) | 미측정 | 없음 (`knip` 미도입) | 없음 |

핵심 관찰:

1. **`audit-dead-surface.py`는 CI에 연결되어 있지 않다** — 아주 정교한 도구(warning-32 false-green 함정까지 docstring에 문서화)가 수동 방치 중.
2. **OCaml lib/ 빌드 코드는 이미 dead-free** (`audit-dead-surface --modules` = 0). 07-21 감사의 효과. 단 이 도구는 *빌드 그래프 내* module만 잡고, 빌드밖 .ml·문서·스크립트·TS는 스코프 밖이다.
3. **`lib/dune`의 `(include_subdirs unqualified)`** 때문에 lib/ 트리 전체가 한 라이브러리로 빌드된다. 따라서 "tracked .ml은 어떤 dune 타겟에 속해야"라는 게이트는 lib/에선 무의미하다 — 빌드고아는 lib/ 밖(docs/fixtures/examples)에만 존재한다.

## 5. RFC-0151 선례와 교훈 (설계의 출발점)

**RFC-0151** (4-metric monotone-decrease ratchet)은 **Withdrawn (2026-05-29)** 상태다. 폐기 사유를 그대로 인용한다:

> "its maintenance cost exceeded its signal value... every increase required a paired baseline regenerate PR... recurring baseline-drift false-fails blocked every open PR until a regenerate PR landed — **the ratchet became a workspace collaboration tax rather than a guard**."

즉 masc는 이미 "현재 위반 수를 baseline으로 고정하고 증가를 금지하는 monotone ratchet"을 시도했고, **baseline drift가 모든 열린 PR을 블록하는 협업 세금**이 되어 제거했다. 같은 패턴의 재도입은 동일한 실패를 재현한다. 07-22 관찰(code-smell ratchet waiver가 `github.event.pull_request.body`에서 읽어 rerun이 무효 → push로 synchronize 필요)도 같은 함정의 다른 표면이다.

**교훈: 전수 baseline monotone ratchet은 기각한다.** 본 RFC의 게이트는 (a) baseline을 갖지 않거나, (b) PR을 블록하지 않는 방향으로 설계한다.

## 6. Design — baseline-free 게이트

### 6.1 PR-diff 스코프 게이트 (R3 차단, drift 없음)

**새로 추가되는 파일만** 검사한다. baseline/전수 비교가 없으므로 drift가 발생하지 않는다.

- lint: PR에서 *추가된* tracked 파일에 대해서만 dead 후보 검사.
  - `.ml`/`.mli` 추가 시: `audit-dead-surface.py`에 새 module을 주입해 즉시 참조 여부 판정 (전수 실행 아님, diff 스코프).
  - `scripts/*.{sh,py}` 추가 시: 해당 basename이 `.github/`·`Makefile`·`mk/`·`run-lint-suite.sh`·런북 중 최소 1곳에서 호출되는지. 0 caller면 **allowlist 필수** (PR에서 allowlist 항목 추가로 승인).
  - `dashboard/**/*.ts` 추가 시: `knip`이 해당 export를 import 그래프에서 도달 가능하다고 판정.
- **drift 없음**: baseline이 없으므로 regenerate PR도, 열린 PR 블록도 없다. 각 PR은 자기가 추가한 파일에 대해서만 책임진다.

### 6.2 코드-삭제-연동 게이트 (R1 직격, 근본 원인)

누적의 근본 원인(R1)은 "코드 삭제 시 연관 문서/스크립트/fixture 삭제 누락"이다. 이를 PR 단위에서 잡는다.

- lint: PR diff에서 **삭제된** module/function/tool을 추출한다 (`git diff`에서 `-` 라인의 module 참조, 혹은 삭제된 `.ml`의 module명).
- 그 module명을 참조하는 **tracked 문서/스크립트**가 같은 PR에서 삭제되지 않았으면 경고.
  - 예: PR이 `lib/handover_eio.ml`을 삭제하는데 `docs/CELLULAR-AGENT.md`가 같은 PR에 없고 여전히 `masc_handover`를 참조 → 경고.
- 단, 기존 파일(수정 없음)은 검사하지 않는다 — **R1은 새로운 삭제 이벤트에만 적용**. 이것이 baseline 없이 작동하는 이유다.

### 6.3 nightly non-blocking 보고 + 자동 issue (R2/R3 발각, 블록 아님)

전수 감사는 느리고(audit-dead-surface 300s+) drift 위험이 있어 **PR 게이트가 아닌 nightly 보고**로 둔다.

- nightly: `audit-dead-surface.py` + 문서/스크립트 orphan 스캔을 돌려 결과를 아티팩트로 남기고, 증가분이 있으면 **GitHub issue를 자동 생성**(라벨 `dead-surface`).
- **PR을 막지 않는다.** RFC-0151의 협업 세금 회피. 발각은 하되 판단은 인간(issue triage).
- baseline은 "직전 nightly 실행 대비 증가분"만 — 영구 baseline이 아니라 rolling diff이므로 drift가 누적되지 않는다.

### 6.4 docs/fixtures/ .ml 정책 (R2)

`lib/` 밖 `.ml`은 dune이 모르고 참조 검증도 안 된다. 두 정책 중 오너 결정:

- (a) **금지**: `docs/`, `fixtures/`, `examples/` 아래 `.ml`을 lint로 금지 (`.md`로 변환 권장). 가장 단순.
- (b) **allowlist**: 허용 파일만 명시. 유연하지만 관리 비용.

### 6.5 warning-32 게이트 (선택, OCaml unused value)

`audit-dead-surface.py` docstring이 지적한 함정: `OCAMLPARAM='_,w=+32'`를 **별도 build dir**에서 돌려야 한다 (`_build`를 공유하면 cache hit으로 false green). 이것만 별도 CI job으로 두면 unused value를 컴파일러가 증명한다. 단 느리고 별도 빌드 비용이므로 nightly 권장.

## 7. 고려한 대안 (기각)

| 대안 | 기각 사유 |
|------|-----------|
| **전수 monotone ratchet** (RFC-0151 재현) | baseline drift → 협업 세금. §5 선례 |
| **정기 sweep 스크립트만** | symptom 억제. 발각은 하되 누적 원인(R1) 방치. CLAUDE.md 워크어라운드 거부 기준 위반 |
| **자동 삭제** | `tokens.generated.ts` 오판 사례(5 importer가 dead로 둔갑)가 증명하듯 false positive가 머지되면 기능 손실. **자동 탐지는 OK, 자동 삭제는 금지** |
| **allowlist 없는 caller-0 스크립트 게이트** | 104개가 전부 빨강. 초기 분류(allowlist 시드) 없이 게이트를 달면 아무도 안 쓴다 |

## 8. allowlist 정책 (초기 비용 관리)

104 caller-0 스크립트 / 92 withdrawn 문서는 false positive 투성이다 (operator 수동 실행, RFC/audit 영구 기록, 의도적 placeholder). allowlist 없는 게이트는 즉시 빨강투성이가 된다.

- **초기 시드**: 2026-07-23 sweep 결과(37 dead 검증 + 살아있는 것 분류)를 allowlist 시드로 사용. 비결정적 분류 비용을 워크플로우로 한 번에 지불.
- **정책**: allowlist 항목은 *이유 코멘트* 필수 (예: `# operator-run, not CI-wired`). 새 항목 추가 시 PR에서 사유 명시.
- **6.1 PR-diff 게이트**는 allowlist 초기화 없이 즉시 도입 가능 — 새 파일만 보므로 기존 104/92개는 스코프 밖. 이것이 baseline-free 설계의 실질적 이점이다.

## 9. 한계 / Non-goals

1. **완전 자동화는 환상.** "이 일회성 스크립트/withdrawn 문서를 살릴까"는 본질적으로 인간 판단이다. 게이트는 누적을 늦추고 발각을 자동화할 뿐, 판단을 대체하지 않는다.
2. **게이트 우회 리스크.** 개발자가 allowlist에 항목을 추가해 게이트를 우회할 수 있다. allowlist 증가 자체를 monthly 리뷰로 모니터링한다 (§6.3 nightly 보고에 allowlist size 추적 포함).
3. **TS unused(knip)는 dashboard 범위로 제한.** 전 repo TS 그래프 분석은 비용이 크다.

## 10. 우선순위 / Rollout

| 단계 | 작업 | 의존성 | 게이트 종류 |
|------|------|--------|-------------|
| **P1** | 6.1 PR-diff 스코프 게이트 (새 스크립트 caller 검사 + 새 .ml 빌드/참조 검사) | allowlist 불필요 | **blocking** |
| **P1** | 6.2 코드-삭제-연동 게이트 | 없음 | **blocking** |
| **P2** | 6.3 nightly 보고 + 자동 issue | audit-dead-surface + orphan 스캐너 | **non-blocking** |
| **P2** | 6.4 docs/fixtures .ml 정책 (a/b 오너 결정) | 정책 결정 | blocking |
| **P3** | knip 도입 (TS, dashboard) | dashboard 빌드 그래프 | blocking (dashboard) |
| **P3** | 6.5 warning-32 nightly job | 별도 build dir CI | non-blocking |

P1 두 항목이 핵심 — baseline 없이 즉시 도입 가능하고, R1/R3(누적의 주원인)을 직격한다.

## 11. 검증 방법

- **6.1**: 의도적으로 caller-0 스크립트를 추가한 더미 PR에서 게이트가 fail하는지 확인. allowlist 추가 시 pass.
- **6.2**: 모듈 삭제 + 연관 문서 미삭제 PR에서 경고가 나는지 확인.
- **재현성**: `audit-dead-surface.py`가 07-23 sweep 결과(lib/ dead=0)와 일치하는지 이미 검증됨.
- **회귀 없음**: 기존 49개 lint ratchet과 충돌하지 않는지 `run-lint-suite.sh` 통합 테스트.

## 참조

- `scripts/audit-dead-surface.py` (docstring: warning-32 함정, token boundary 매칭)
- RFC-0151 (monotone ratchet, **Withdrawn** — 본 RFC의 기각 선례)
- RFC-0249 (개별 dead field 점적 제거 — 본 RFC는 누적 *방지* 시스템으로 complement)
- PR jeong-sik/masc#25637 (2026-07-23 T1 dead-file 삭제, 검증 방법론의 실증)
- CLAUDE.md "워크어라운드 거부 기준" (symptom 억제 vs 근본)
