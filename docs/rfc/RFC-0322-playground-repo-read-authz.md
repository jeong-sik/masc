---
rfc: "0322"
title: "Keeper self-registration of own-sandbox repos: stop keepers blocking on operator approval for repos they already cloned, without opening a fail-open hole"
status: Draft
created: 2026-07-08
updated: 2026-07-08
author: vincent (+ Claude Opus 4.8)
supersedes: []
superseded_by: null
related: ["0006", "0312"]
implementation_prs: []
---

# RFC-0322: Keeper self-registration of own-sandbox repos

keeper가 자기 sandbox에 **이미 clone한** repo를 읽으려는데 카탈로그에 미등록이면, 지금은 운영자 HITL 승인을 기다리며 멈춘다("깽판"). 이 repo는 keeper가 정당한 경로로 이미 clone한 것이므로, 운영자 승인 없이 **keeper가 스스로 등록**하고 진행하게 한다. 단 fail-open을 열지 않고(카탈로그가 여전히 SSOT), cross-keeper 등록을 막는다.

이 RFC는 이전에 논의된 fail-open flip(#23609 merge → main red, #23660으로 revert; #23590/#23638)을 **폐기**한다. 정답은 "미등록을 허용으로 표시"가 아니라 "미등록을 등록으로 승격"이다.

## 1. Problem — 자가치유가 운영자 게이트에 막혀 있다

실측 흐름(workflow 매핑, 2026-07-08):

1. keeper가 playground의 미등록 repo 경로를 읽으려 함.
2. `Keeper_repo_claim_hitl.request_path_access` (`keeper_repo_claim_hitl.ml:415`) → `access_decision` (`keeper_repo_mapping.ml:401`)이 `Access_denied (Unregistered_repository)`.
3. `request_path_access`는 `registration_candidate_of_path`로 on-disk clone을 탐지하면 **HITL 등록 승인을 제출**하고 `Access_denied_hitl_pending`을 반환(`keeper_repo_claim_hitl.ml:420-425`).
4. keeper는 `operator_action_required / wait_for_operator_approval`을 받고 멈춤. deterministic policy-block + failure-counter jump으로 재시도도 차단됨(`keeper_tools_oas_handler_exec.ml:218`).

즉 무한루프가 아니라 **운영자 승인 대기로 멈추는 것**이 "깽판"의 실체다.

## 2. Design — 승인 전에 self-register, 실패 시 HITL fallback

**Hook**: `request_path_access`의 `Access_denied` arm, candidate 존재 sub-branch (`keeper_repo_claim_hitl.ml:420-434`). HITL 제출 **전에** self-registration을 시도한다.

**조건 (모두 만족해야 자동 등록)**:
1. `registration_candidate_of_path`가 성공 = 실제 `.git` worktree가 그 경로에 물리적으로 존재(`keeper_repo_claim_hitl.ml:365-377`).
2. **candidate repo_root가 *호출한 keeper 자신의* playground 안**이다 — `target_is_inside_playground ~playground:(playground_root_abs ~config ~meta) ~target:candidate.repo_root`. **profile 무관하게 강제**(Local 프로파일은 containment가 스킵되므로 이 가드가 cross-keeper 등록을 막는 유일한 방어선이다, §4).
3. identity 일치 — `candidate_identity_is_valid ~keeper_id` (url basename == segment id, `keeper_repo_mapping.ml:571-574`) AND `candidate_expected_repo_root_mismatch = false`.

**동작**:
- 조건 통과 → `Repo_store.register_discovered_path ~base_path ~repository_id ~repo_path:candidate.repo_root` (신규). resolved `repository_id`(segment, `keeper_repo_mapping.ml:669-675`)로 등록 — **`slugify_id(basename)`로 재-slug 금지**(id drift 시 등록 후에도 membership 불일치로 계속 거부됨).
- 등록 후 **fail-closed 경로로 정확히 1회 재인가**(`authorize_resolved_path` 헬퍼로 추출). `repository_resolution_of_path`가 identity-mismatch를 다시 검사하므로, 자기모순 엔트리는 `Repository_identity_mismatch → Access_denied`로 여전히 거부.
- `Access_allowed`만 성공. 그 외(identity mismatch / 여전히 denied) → **기존 `submit_registration_hitl` fallback**.
- 조건 미통과(candidate 없음 / cross-playground / identity invalid) → **기존 HITL 동작 그대로**(동작 변화 없음).

재귀는 1회로 bound. 성공 시 `Keeper.info` 로그(keeper, repository_id, path).

## 3. 왜 fail-open이 불필요한가

등록되면 `access_decision`이 `repository_registered=true`라 **정당한 이유로** `Access_allowed`를 반환한다. `policy_allowed` projection의 의미("정책이 read 인가")도 보존된다. #23609의 flip(projection만 `true`로 표시)은 실제 게이트를 안 바꿔 divergence만 만들었고, 이 설계는 그 문제를 원천 제거한다.

## 4. Security

| 통제 | 근거 |
|------|------|
| **own-playground 가드** | candidate.repo_root가 호출 keeper의 playground 안일 때만 등록. Local 프로파일은 `check_target`이 `is_hardened_profile Local=false`로 containment를 스킵(`keeper_sandbox_containment.ml:19-21`)하므로, 이 가드가 없으면 Local keeper A가 keeper B의 playground 경로로 B의 repo를 자동 등록할 수 있다. **이 가드가 cross-keeper 등록을 막는 유일한 방어선.** |
| **identity 보존** | 사전 `candidate_identity_is_valid` + 사후 `repository_resolution_of_path`의 `Repository_identity_mismatch`. url basename이 segment id와 불일치하면 자동 등록 거부 → HITL로 라우팅. |
| **no fail-open** | `access_decision`이 legitimately `Access_allowed`일 때만 허용. denied string 경로와 deterministic policy-block 계약은 self-heal 안 되는 모든 케이스에서 불변. |
| **idempotent** | `register_discovered_path`는 id + canonical local_path로 dedup. 반복 denial/동시 keeper가 중복 엔트리 안 만듦. |
| **atomic write** | 자동·빈번한 쓰기가 `save_all`(`repo_store.ml:174-192`)의 non-atomic truncate-in-place + unguarded read-modify-write 손상 창을 키운다. temp+rename로 원자화. |

## 5. Governance (결정 필요)

이 설계는 keeper→catalog 쓰기를 게이트하던 **운영자 HITL을 self-service로 대체**한다(own-sandbox + identity-valid 케이스 한정). 보상 통제는 sandbox-presence + own-playground + identity-consistency다.

- **all-keeper 접근(기존 semantics)**: 등록은 그 repo id를 *모든* keeper에게 연다(`keeper_repo_mapping.ml:412-423`). 이 RFC가 새로 만든 게 아니라 기존 동작이지만, 자동 등록이 빈번해지면 노출이 늘 수 있다. per-keeper mapping(RFC-0312 advisory) 스코프를 추가할지는 open question.
- **대안**: 운영자 승인을 유지하되 repo-owner policy flag가 켜진 keeper에만 자동 등록. (기본 off → opt-in.)

## 6. 구현 + 검증

- `repo_store.ml`: `candidate_of_repo_dir` 추출 + `register_discovered_path ~base_path ~repository_id ~repo_path` 신규(dedup+save_all 재사용, hidden-`.masc` 필터 미적용). `.mli` export. `save_all` 원자화.
- `keeper_repo_claim_hitl.ml`: `authorize_resolved_path` 추출 + `request_path_access`에 self-register-then-reauthorize 배선(§2).
- `test/test_keeper_repo_self_registration.ml` (신규):
  - **회귀**: repos/X 미등록 + own playground clone(origin basename==X) → 1회 호출에 `Access_allowed` + 카탈로그에 id=X 엔트리. (pre-fix baseline: `authorize_resolved_path`는 `Access_denied`.)
  - **identity 보존(no fail-open)**: origin basename != Y인 clone → 자동 등록 안 함 → `Access_denied_hitl_pending` + 카탈로그 불변.
  - **cross-keeper 차단**: keeper B의 playground 경로를 keeper A로 호출 시 자동 등록 안 함.
  - **bounded retry**: id drift 주입 시 정확히 1회 재시도 후 HITL fallback(무한재귀 없음).
  - **unit**: `register_discovered_path`가 resolved id(재-slug 아님)로 정확히 1 엔트리, 2회차 `Ok []`.

## 7. Open questions

- cross-keeper: `request_path_access`의 `~path`가 항상 호출 keeper 자신의 playground로 제한되는지는 caller-level allowed_paths에 의존. own-playground 가드(§4)로 방어하되, 상위 resolver 스코프도 확인 권장.
- all-keeper 접근을 per-keeper mapping으로 좁힐지.
- `save_all` 원자화를 이 PR에 포함할지 선행 작업으로 뺄지.
