---
rfc: "0322"
title: "Playground repo read authorization: catalog registration이 read 게이트인가, containment이 게이트이고 catalog는 metadata인가"
status: Draft
created: 2026-07-08
updated: 2026-07-08
author: vincent (+ Claude Opus 4.8)
supersedes: []
superseded_by: null
related: ["0006", "0312"]
implementation_prs: []
---

# RFC-0322: Playground repo read authorization 경계

keeper playground에서 **등록되지 않은(unregistered) repo를 언제 read 허용하는가**를 확정한다. 현재 이 결정이 RFC 없이 세 PR(#23609 / #23590 / #23638)로 쪼개져(N-of-M) 흐르며 보안 기본값을 fail-closed → fail-open으로 바꾸고 있다. 개별 PR은 각각 "mergeable-after-fix"지만, 합치면 하나의 authz 경계 결정이다.

## 1. Problem — 게이트의 소유권이 두 곳으로 갈렸다

keeper는 자기 sandbox의 `repos/` 아래에서 repo clone을 파일로 관측한다. 어떤 repo를 read 허용할지 결정하는 지점이 두 개 있다:

1. **Catalog registration** (`repositories.toml`) — 현재 binding 게이트. repo가 카탈로그에 등록되어 있어야 `policy_allowed=true`. 미등록이면 `Policy_unregistered_repository`로 `policy_allowed=false` (fail-closed, 거부).
2. **Sandbox containment** (`check_read_target`, RFC-0006) — 경로가 sandbox 루트를 벗어나지 않는지 검사하는 두 번째 방어선. 현재는 defense-in-depth로 catalog 게이트 *뒤*에 있다.

### 1.1 클러스터가 하려는 변경 (같은 방향, 별개 PR)

- **#23609** (`keeper_sandbox_control.ml:447,469`): `Policy_unregistered_repository false` → **`true`**. 미등록 repo의 `policy_allowed`를 fail-closed에서 "containment에 위임"으로 뒤집는다. 자기 테스트(`test_policy_source_of_status`, `test_keeper_repo_mapping`)와 모순되어 **Build FAIL**. + `keeper_tool_shared_runtime.ml`의 alias 해석(별칭→canonical, authz 중립) 기능이 같은 PR에 번들됨.
- **#23590** (`keeper_repo_mapping.ml:675`): `None -> Repository(deny+HITL)` → `None -> No_repository(허용)`. fail-closed → fail-open. `rejects_*_spoof` identity 테스트 5개를 전부 `allows`로 전환.
- **#23638** (`keeper_repo_claim_hitl.ml:408`): repo-id denial을 HITL로 reroute. 직접 caller 없어 현재는 vacuous.

### 1.2 근본 문제

1. **RFC 부재**: `lib/repo_manager/`, `keeper_sandbox_control.ml`은 `agent_delegation` + `workflow-pr.md` item 11이 RFC 인용을 필수로 하는 subsystem인데 세 PR 모두 RFC 참조/`RFC-WAIVED`가 없다.
2. **`policy_allowed` 의미 변질 (SSOT 위반)**: flip 후 `policy_allowed=true`는 더 이상 "정책이 read를 인가"가 아니라 "catalog가 거부하지 않음, containment에 위임"이 된다. 이 필드를 authz 신호로 읽는 소비자(JSON projection, 대시보드)가 오도된다. projection과 실제 read 인가가 divergence한다.
3. **identity-spoof 방어 축소**: 스푸핑 방어 테스트를 허용으로 뒤집으면 회귀 방어가 약해진다.
4. **N-of-M**: "언제 미등록 repo를 read 허용하나"는 하나의 정책 결정인데 세 PR로 쪼개져 각 리뷰가 전체 그림을 못 본다.

## 2. 결정해야 할 것 (Decision)

**미등록-but-visible playground repo의 read 인가를 무엇이 소유하는가?**

- **Option A (권장) — Catalog가 read 게이트, fail-closed 유지.** 미등록 repo는 `policy_allowed=false`로 거부한다. catalog 등록이 read의 전제. containment는 defense-in-depth(두 번째 방어선)로 남는다. alias 해석 기능은 authz를 안 바꾸므로 별도 PR로 분리 머지한다.
- **Option B — Containment가 read 게이트, catalog는 metadata/identity.** 미등록-but-visible repo는 `policy_allowed`를 containment(`check_read_target`)에 위임한다. catalog는 alias/identity 소유만. 이 경우 `policy_allowed`의 의미를 "catalog 미거부"로 재정의하고, projection 필드명을 그 의미에 맞게 바꿔 divergence를 없앤다.

### 2.1 권장: Option A

근거:

1. **매니페스트 anti-pattern**: "Unknown → Permissive Default (조용한 허용)"는 `software-development.md`가 명시적으로 거부하는 AI 코드 안티패턴이다. 미등록(unknown registration) → 허용은 정확히 이 형태다.
2. **containment은 방어선이지 인가 근거가 아니다**: RFC-0006 containment는 "sandbox 밖으로 못 나감"을 보장하지 "이 repo를 읽어도 됨"을 인가하지 않는다. 두 개념을 하나의 게이트로 합치면(Option B) 인가와 봉쇄가 결합되어 경계가 흐려진다. "경계를 정확하게 구분"(`software-development.md`)에 반한다.
3. **`policy_allowed` 의미 보존**: Option A는 `policy_allowed=true`가 "정책이 read를 인가"라는 뜻을 유지한다. divergence가 발생하지 않는다.
4. **회귀 방어 유지**: identity-spoof 테스트를 허용으로 뒤집지 않는다.

Option B가 정당화되려면: playground 사용성에서 "카탈로그 미등록이지만 이미 clone된 repo를 read해야 하는" 구체적 워크플로가 있고, 그 repo의 identity를 containment만으로 충분히 신뢰할 수 있다는 근거가 필요하다. 이 근거가 문서화되면 Option B로 전환하되, `policy_allowed` 필드를 재명명하고 divergence를 코드/테스트로 닫아야 한다.

## 3. 클러스터 재정렬

### Option A 채택 시
- **#23609**: alias 해석 부분(`keeper_tool_shared_runtime.ml`, authz 중립)만 새 PR로 분리 → 머지 가능. `keeper_sandbox_control.ml:447,469` flip은 되돌려 fail-closed 복원(Build green 회복). repo_manager 터치는 본 RFC를 인용.
- **#23590**: `None -> Repository(deny+HITL)` 유지(revert). identity-spoof 테스트 5개 원복.
- **#23638**: repo-id denial → HITL reroute는 vacuous(직접 caller 없음)이므로 live caller 배선 또는 폐기.

### Option B 채택 시
- 세 PR을 본 RFC 아래로 통합. `policy_allowed` → 예: `catalog_registered` + `read_authorized`로 분리(projection이 실제 authz와 일치). identity-spoof 테스트는 유지하되 "새 정책에서 무엇이 여전히 거부되는가"를 명시적으로 커버.

## 4. 검증 (Option 무관 공통)

1. `policy_allowed`(또는 후속 필드)가 실제 `check_read_target` 결과와 일치함을 property 테스트로 고정한다 — projection↔authz divergence 금지.
2. identity-spoof 방어를 behavioral 테스트로 유지한다(Option A는 현행 유지, Option B는 재정의된 거부 케이스).
3. FSM/match는 catch-all `_ ->` 없이 registration 상태(registered / unregistered / store_error / mapping_error)를 exhaustive하게 처리한다.

## 5. 완화요인 (현재 위험도)

containment(`check_read_target`)는 무손상이므로 flip이 머지되어도 **현재 당장 sandbox escape는 아니다.** 그러나 authz 기본값 변경은 그 자체로 RFC 대상이며, `policy_allowed` divergence는 관측/감사 신뢰를 훼손한다. 세 PR 모두 Draft로 contained되어 있어 배포 위험은 없다.

## 6. 미해결 질문

- alias 해석 기능(#23609의 절반)이 `lib/repo_manager/`를 터치하는데, 이 기능만 단독으로도 RFC 인용이 필요한가, 아니면 authz 중립이라 waiver 가능한가?
- Option B로 갈 경우 `keeper_repo_mappings.toml`(advisory, RFC-0312)과 containment authz의 우선순위 관계.
