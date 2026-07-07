---
rfc: "0316"
title: "Merge gating convergence: enforce_admins=true + live Branch Protection Watchdog"
status: Draft
created: 2026-07-07
updated: 2026-07-07
author: vincent
supersedes: []
superseded_by: null
related: ["0235", "0313"]
implementation_prs: []
---

# Merge gating convergence: enforce_admins=true + live Branch Protection Watchdog

## 1. Problem

main의 required check는 `CI Gate` 하나로 선언되어 있으나, `enforce_admins=false`이므로 admin 토큰 머지는 CI Gate의 완료 여부와 무관하게 통과한다. fleet keeper와 운영자 모두 같은 admin 토큰 계열로 머지하므로, 사실상 **모든 머지가 게이트를 우회 가능**한 상태다.

이 우회는 관념적 리스크가 아니라 반복 실측된 유입 경로다. 2026-07-07 하루 동안 main red 4계열이 전부 같은 패턴(merge-before-green: 머지 시점에 진행 중이던 CI가 취소되어 red가 관측되지 않은 채 착지)으로 들어왔다:

| 계열 | 유입 PR | 증상 (run 28866108272, job 85616608933) | 수리 |
|---|---|---|---|
| A | #23539 | `test_otel_zero_fill` tripwire 251→252 | #23561 |
| B | #23534 | `staleness_gate #3` fresh dk — 검증력 0 테스트 | #23567 |
| C | #23524 | auto-pause loop 4건 — W3 flip 테스트 미동기 | #23552, #23560 |
| D | #23486 | board coverage 11건 (comments 8 + dispatch 2 + cache 1) | #23527 (open) |

머지 시점 CI 취소(cancelled-at-merge)의 직전 실측만으로도 #23524, #23534, #23537, #23539, #23552가 확인된다. 취소된 런은 pass로도 fail로도 기록되지 않으므로, red는 다음 main 런에서야 발현되고 그 사이에 머지된 모든 PR이 오염된 기준선을 상속한다. 오염된 기준선 위에서는 "이 PR이 새 실패를 추가했는가"를 FAIL 집합 비교로만 판별할 수 있게 되어, 리뷰·검증 비용이 매 PR마다 발생한다.

감시 장치는 이미 존재한다. `.github/workflows/branch-protection-watchdog.yml`은 `scripts/ci/check-main-branch-protection.sh`로 정확히 `enforce_admins=true` + required contexts `CI Gate`를 기대한다. 그러나:

1. 현실이 기대와 달라(`enforce_admins=false`) 드리프트 상태이고,
2. `BRANCH_PROTECTION_AUDIT_TOKEN` secret이 미설정이라 push/schedule 런이 **토큰 부재 사유로** fail-closed 실패한다.

결과적으로 Watchdog은 "늘 우는 알람"이 되어 무시되고 있으며(2026-07-07 관측: 모든 PR/main 런에서 상습 fail), 드리프트 fail과 토큰 부재 fail이 구분되지 않는다.

## 2. Goal

이미 코드로 선언된 목표 상태로 현실을 수렴시킨다:

1. `enforce_admins=true` — admin 포함 모든 머지가 `CI Gate` 성공 완료를 전제.
2. `BRANCH_PROTECTION_AUDIT_TOKEN` 설정 — Watchdog을 살아있는 드리프트 알람으로 복원.

Non-goal: merge queue 도입(User 소유 repo에서는 GitHub merge queue를 사용할 수 없다 — organization 소유가 전제. 공식 문서 재확인 필요), `strict`(require branches up-to-date) 활성화(§5), required contexts 확장.

## 3. Design

### 3.1 enforce_admins=true

설정 자체는 GitHub API 한 줄이다 (운영자 실행):

```bash
gh api -X POST repos/jeong-sik/masc/branches/main/protection/enforce_admins
```

효과: `gh pr merge`는 CI Gate가 성공 완료 상태가 아니면 admin 토큰으로도 거부된다. cancelled-at-merge 클래스가 구조적으로 소멸한다(진행 중 CI를 남긴 채 머지할 수 없으므로 취소도 없다).

### 3.2 Watchdog 토큰

`BRANCH_PROTECTION_AUDIT_TOKEN`은 branch protection 읽기 권한(repo admin read)이 있는 fine-grained PAT로 설정한다 (운영자 실행: repo Settings → Secrets). 이후 Watchdog의 의미가 복원된다:

- green = 설정이 선언 상태와 일치
- red = 실제 드리프트 (누군가 enforce를 내렸거나 required context가 사라짐)

### 3.3 데드락 분석 — 왜 이것이 기능인가

enforce 활성 후 main이 red가 되면(이론상 flaky/인프라 실패로 여전히 가능) 모든 PR의 merge-ref CI가 그 red를 상속하여 머지가 전면 정지한다. main red N계열이 서로 다른 fix PR로 나뉘면 각 PR이 나머지 계열을 상속해 전부 red — 상호 데드락이다.

이는 버그가 아니라 Always Deployable의 정확한 구현이다: main이 red면 red 수리 외의 진행은 멈추는 것이 맞다. 탈출구는 항상 존재한다:

1. **통합 수리 PR**: N계열을 하나의 PR로 묶으면 그 PR의 merge-ref는 green이 된다. lane 소유권보다 main green 복구가 우선한다.
2. **명시적 일시 해제**: 운영자가 `gh api -X DELETE .../enforce_admins`로 내리고 수리 머지 후 즉시 복원한다. Watchdog(3.2)이 내려간 상태를 스케줄 런마다 red로 기록하므로, 해제는 은폐 불가능한 감사 흔적을 남긴다.

오늘 같은 4계열 상황은 enforce가 켜져 있었다면 애초에 발생하지 않았다 — 4계열 전부 merge-before-green 유입이므로, 데드락 시나리오는 주로 전이 기간의 것이다.

### 3.4 전이 순서 (순서가 본질)

main이 red인 상태에서 enforce를 켜면 즉시 3.3의 정지 상태로 들어간다. 따라서:

1. 잔여 main red 해소를 확인한다 — 현재 B(#23567)와 D(#23527)가 잔여. A/C는 착지 완료.
2. main 최신 커밋의 `CI Gate` green을 확인한다.
3. 3.1 + 3.2를 적용한다.
4. 직후 첫 PR 머지에서 게이트가 실제로 작동하는지(green 전 머지 거부) 확인한다.

### 3.5 Fleet 행동 영향

keeper가 required green을 기다리지 않고 merge를 시도하는 기존 행동은 enforce 후 GitHub API 에러로 돌아온다. 이 에러는 keeper 입장에서 새로운 실패 모드이므로:

- keeper의 merge 시도가 "checks 대기 후 재시도"로 수렴하는지 초기 관찰이 필요하다.
- merge 거부 에러를 hard failure로 오분류해 PR을 닫거나 재작성하는 행동이 관찰되면 그 시점에 typed 처리(RFC 분리)를 추가한다. 선제 구현은 하지 않는다(관측 전 추측 구현 금지).

## 4. Verification

- 적용 직후: `bash scripts/ci/check-main-branch-protection.sh` 로컬 실행(토큰 필요) 또는 Watchdog workflow_dispatch 런이 green.
- 게이트 실증: CI 진행 중인 아무 Draft PR에서 `gh pr merge`가 거부되는지 확인.
- 1주 관측: cancelled-at-merge 발생 건수 0 유지 (`gh run list`에서 merge 커밋 시각과 CANCELLED 런 교차 확인).

## 5. Alternatives considered

- **merge queue**: cancelled-at-merge와 stale merge-ref를 동시에 푸는 정답이지만 User 소유 repo에서 불가. org 이전은 이 RFC 범위 밖.
- **strict=true (up-to-date 강제)**: stale merge-ref 기준 green 머지를 막지만, fleet 규모(동시 수십 PR)에서 매 main 착지마다 전 PR 리베이스 경쟁이 발생해 처리량이 급감한다. merge queue 없이 strict만 켜는 것은 비용 대비 이득이 없어 보류.
- **required contexts 확장** (Build and Test 등 개별 추가): CI Gate가 이미 aggregator이므로 중복. 우회 경로는 contexts 수가 아니라 enforce_admins에 있었다.
- **프로세스 규칙만으로 해결** ("green 확인 후 머지하기로 약속"): 오늘 4계열이 반증. 규칙은 admin 토큰의 기술적 우회 앞에서 강제력이 없다.

## 6. Rollout / rollback

- Rollout: §3.4 순서. 설정 변경은 코드 배포가 없으므로 즉시 적용/즉시 관찰.
- Rollback: `gh api -X DELETE repos/jeong-sik/masc/branches/main/protection/enforce_admins`. Watchdog이 red로 기록하므로 rollback 상태가 조용히 지속될 수 없다.
