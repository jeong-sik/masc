---
rfc: "0078"
title: "RFC Number Reservation Ledger + CI Collision Guard"
status: Draft
created: 2026-05-14
updated: 2026-05-14
author: vincent
supersedes: []
superseded_by: null
related: ["0057", "0058"]
implementation_prs: []
---

# RFC-0078: RFC Number Reservation Ledger + CI Collision Guard

## §1 Problem (caller-context)

`docs/rfc/README.md:7` 의 정책은 "작성 시점에 사용 가능한 가장 작은 4자리 번호. `git fetch origin main && ls docs/rfc/` 로 race-check 후 commit. main 머지 시점에 다른 PR 이 같은 번호를 점유했다면 즉시 renumber 한다." 라는 *수동 race-check + 사후 renumber* 패턴에 의존한다.

이 정책의 실패 사례:

- 2026-05-09 RFC-0057 충돌 (#14396 vs #14394) — `feat/rfc-0057-tool-descriptor-codegen` vs `feat/rfc-0057-goal-scope-observation-claim-atomicity` 가 동일 번호 점유. #14672 에서 `goal-scope-observation` 측을 RFC-0067 로 renumber. memory feedback `feedback_rfc_number_reservation_needed` 에 root-cause "동시 작성자 git pull latency 내 중복 claim" 으로 기록.
- 2026-05-14 RFC-0074 충돌 — #15064 (`RFC-0073~0076 tool readiness package`) 의 RFC-0074 (`sandbox-credential-auto-provision`) vs #15137 (`RFC-0074 telemetry envelope`). commit `bcc281fa03` 에서 사용자가 #15137 측 RFC-0073 을 *RFC-0077* 로 수동 renumber. 5일 만의 재발.

`.github/workflows/rfc-enforcer.yml:1-40` + `scripts/rfc_enforcer.py:1-237` 는 §1 completeness (TODO/citation/code-block) 만 검사하고 번호 충돌은 검사하지 않는다 (`scripts/rfc_enforcer.py:57-237` 의 `check_rfc_file` 함수는 §1 텍스트만 본다). `docs/rfc/README.md:118-119` 의 "다음 신규" 메모는 작성자가 직접 갱신하므로 동시 PR 시 race.

`~/me/scripts/pr-rfc-check.sh` 는 *다른* 목적 (subsystem 변경 시 RFC 인용 강제) 이고 번호 검사 없음.

근본 원인: **번호 점유를 PR 작성 시점에 강제 사전 차단하는 메커니즘이 없다.** 모든 가드가 *사후* 동작.

## §2 Approach

두 층 방어:

**Layer A — Ledger 파일 `docs/rfc/.next-number`**

단일 정수 한 줄 (예: `0079`). RFC 작성자는 PR 시작 시 `scripts/rfc-allocate-next.sh` 호출 → 현재 값 read + +1 로 갱신 + 같은 commit 에 RFC 파일 추가. 같은 base 에서 두 작성자가 동시에 갱신 시도하면 두 번째 push 가 *non-fast-forward* 로 reject → git 자체가 race detector.

**Layer B — CI workflow `.github/workflows/rfc-number-collision-check.yml`**

PR diff 에서 `^\+\+\+ b/docs/rfc/RFC-(\d{4})-` 패턴 추출. 각 N 에 대해 `git ls-tree origin/main docs/rfc/RFC-${N}-*.md` 결과가 *같은 PR 의 추가 파일* 이 아닌 *다른 파일* 이면 fail. PR comment 로 "RFC-${N} already used by `<path>`. Allocate next via `scripts/rfc-allocate-next.sh`" 안내.

Multi-phase RFC 패턴 (예: `RFC-0058-declarative-cascade-config.md` + `RFC-0058-phase-5-...md`) 은 *명시적 opt-in* 으로 허용 — PR body 에 `RFC-EXTEND: NNNN` 라인 (또는 본문 frontmatter `extends: "NNNN"`) 이 있으면 main 의 기존 NNNN 위에 phase 추가 가능. 옵트인 없이 같은 NNNN 점유 시 fail.

## §3 Components

### §3.1 `docs/rfc/.next-number`

```
0079
```

(단일 정수 한 줄, 4-digit zero-pad, trailing newline.)

### §3.2 `scripts/rfc-allocate-next.sh`

```bash
#!/bin/bash
set -euo pipefail
LEDGER="$(git rev-parse --show-toplevel)/docs/rfc/.next-number"
[ -f "$LEDGER" ] || { echo "ledger missing: $LEDGER"; exit 1; }
N=$(cat "$LEDGER")
NEXT=$(printf "%04d" $((10#$N + 1)))
echo "$NEXT" > "$LEDGER"
echo "allocated: RFC-$N (ledger advanced to $NEXT)"
echo "$N"
```

작성자 워크플로: `N=$(bash scripts/rfc-allocate-next.sh)` → `git add docs/rfc/.next-number docs/rfc/RFC-${N}-*.md` → commit.

### §3.3 `.github/workflows/rfc-number-collision-check.yml`

trigger: `pull_request` paths `docs/rfc/**`.

job 로직:
1. `gh pr diff` 또는 `git diff --name-only --diff-filter=A origin/main...HEAD` 로 *추가된* RFC 파일 수집
2. 각 파일 이름에서 NNNN 추출
3. `git ls-tree origin/main -- docs/rfc/` 로 main 의 RFC NNNN 목록 수집
4. PR-added NNNN 중 main 에 같은 NNNN 의 *다른* 파일이 있으면:
   - PR body 에 `RFC-EXTEND: NNNN` 또는 frontmatter `extends: "NNNN"` 가 있는지 확인
   - 없으면 fail + PR comment

### §3.4 `scripts/rfc_enforcer.py --check-numbering`

stand-alone CLI 로 같은 검사 (작성자 local pre-push). 기존 `check_rfc_file` 와 동일 디자인.

### §3.5 `docs/rfc/README.md` 정책 갱신

`§정책` 의 "번호 할당" bullet 을 legacy "race-check 후 commit" 에서 ledger 정책으로 교체:

> **번호 할당**: `scripts/rfc-allocate-next.sh` 호출. `.next-number` ledger 갱신과 함께 같은 commit 에 RFC 파일 추가. CI workflow `rfc-number-collision-check` 가 PR 단계에서 origin/main 의 기존 RFC 번호와 충돌 차단. Multi-phase RFC 는 PR body 에 `RFC-EXTEND: NNNN` 또는 frontmatter `extends: "NNNN"` 옵트인 필수.

`§사용 가능한 다음 번호` 섹션 *삭제* — ledger 가 진실의 출처.

## §4 Non-goals

- 기존 RFC retroactive renumber. RFC-0010/0011/0014/0015/0016/0021/0060 의 누락 번호는 *재사용 금지*. ledger 가 모노토닉.
- Frontmatter `rfc:` 필드 검증. 별도 RFC.
- 자동 인덱스 생성 (README 표 자동 갱신). 별도 RFC.

## §5 Test plan

| 시나리오 | 기대 |
|---|---|
| 정상 PR: `.next-number` 0079→0080 + `RFC-0079-foo.md` 추가 | CI pass |
| 충돌 PR: `RFC-0058-collision.md` 추가, PR body 옵트인 없음 | CI fail + comment 생성 |
| Multi-phase opt-in: `RFC-0058-phase-9.md` + PR body `RFC-EXTEND: 0058` | CI pass |
| 동시 PR: 두 worktree 가 `.next-number` 0079→0080 둘 다 변경 | 두 번째 push reject (non-fast-forward) |
| `rfc-allocate-next.sh` 누락 ledger 호출 | exit 1 + 에러 메시지 |

## §6 Citations

- `docs/rfc/README.md:7` — legacy "race-check 후 commit" 정책
- `docs/rfc/README.md:118-119` — 사용 가능한 다음 번호 수동 메모
- `scripts/rfc_enforcer.py:57-237` — 기존 §1 enforcer (참고)
- `.github/workflows/rfc-enforcer.yml:1-40` — 기존 enforcer workflow (sister pattern)
- memory `feedback_rfc_number_reservation_needed` — 2026-05-09 RFC-0057 충돌 기록
- 2026-05-14 commit `bcc281fa03` — RFC-0074 수동 renumber 사례
