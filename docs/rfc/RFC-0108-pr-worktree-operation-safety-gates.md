---
rfc: "0108"
title: "PR / Worktree Operation Safety Gates"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0078"]
implementation_prs: []
---

# RFC-0108: PR / Worktree Operation Safety Gates

## §1 Problem (caller-context)

지난 30일간 agent-led git/PR 작업이 main 의 실제 코드를 *조용히* 손상시킨 사고가 4건이다. 모두 push 시점에 검출 가능했고, 모두 사고-후 hotfix PR 로 회복했다. 공통 패턴은 *push 자체는 fast-forward 가능*인데 *의미적으로* 데이터를 잃는 것이다 (git protocol 안에서 wrong, but valid).

### Incident inventory (실측)

| # | PR | Surface | 손실 |
|---|---|---|---|
| 1 | #15862 (hotfix) | stale-base file copy | PR #15842 의 5 변경이 PR #15850 split 에 의해 silently overwrite. session 안에서 #15842 가 main 에 머지된 사이 PR-5 split 이 pristine copy 시작 → 5변경 zero-out. 근거: `memory/feedback_pr_split_stale_base_overwrites_recent_merges.md` |
| 2 | #15784 (rescue) | post-merge push | 1차 PR #15759 squash-merge 직후, 같은 branch 에 review-fix 2nd commit push → orphan. main 도달 0건. 근거: `memory/feedback_post_merge_push_check_required.md` + `workflow-pr.md §10` |
| 3 | #15618 (sweep) | bare `--force-with-lease` | `git push --force-with-lease` 단독형이 stale local lease 를 honor → upstream advance 했는데도 silent overwrite. step-3 commit 1383+ lines 손실. 근거: `memory/feedback_force_with_lease_stale_info_must_diff.md` (#14904 동일) |
| 4 | #15900/#15901/#15902 (3-way race) | RFC number race | RFC-0107 동시 작성 3 PR. ledger (`RFC-0078`) 가 *내 worktree 안에서만* atomic, 동시 worktree 간 race 못 잡음. ledger 머지된 PR 만 monotonic guarantee. 근거: `memory/feedback_rfc_number_reservation_needed.md` |

### 공통 root

Pre-push 시점에 *upstream 상태와 local 의도의 의미 차이* 를 측정하지 않는다. git 은 fast-forward 와 lease ref 만 검사한다 — *어떤 파일이 upstream 에 있고 내가 모르고 덮어쓰려 하는지*, *branch 가 이미 merged 인지*, *어떤 RFC 번호가 다른 inflight PR 에 있는지* 는 모른다.

`workflow-pr.md §11` 의 `pr-rfc-check.sh` 는 *RFC 인용* 만 검사하고 위 4 surface 에 해당 없음. CLAUDE.md `<agent_delegation>` 는 정책 선언이고 검사 자동화 없음.

근본 원인: **각 surface 마다 사후 memory feedback 으로 룰을 추가했지만, 자동화된 pre-push gate 가 없다.** 같은 agent (다음 세션의 나) 가 memory 를 못 읽으면 동일 사고 재발.

## §2 Approach

Pre-push 시점에 4 typed gate 를 실행. 각 gate 는 *fail-closed*: 통과 못하면 push 차단, 명시적 override flag 필요. agent 가 가독 가능한 한국어 에러 메시지를 stderr 로 출력.

Layer 구성:

- **Layer 1**: 단일 entry-point script `scripts/pr-safety-check.sh` — 모든 gate 를 순차 실행, 첫 실패에서 stop, exit code 와 에러 ID 반환.
- **Layer 2**: Git native `pre-push` hook 이 위 script 호출. `scripts/install-pr-safety-hook.sh` 가 `.git/hooks/pre-push` 에 symlink 설치.
- **Layer 3**: `.claude/hooks/pre_push/` agent-side hook — Claude Code session 안의 Bash `git push ...` 호출 직전에 같은 script 실행 (git hook 이 `--no-verify` 로 우회 가능하므로 agent path 도 별도 가드).

각 gate 는 `0` (pass), `1` (block), `2` (warn — opt-in override) exit code.

## §3 Components

### §3.1 Gate-1: Stale-base overwrite detection

PR split / cherry-pick / file copy 작업이 *long-lived worktree* 안에서 일어나면, base 시점 이후 main 에 머지된 파일을 모르고 덮어쓸 수 있다.

**Algorithm**:

```bash
BRANCH_BASE_SHA="$(git merge-base HEAD origin/main)"
BRANCH_BASE_DATE="$(git show -s --format=%cI "${BRANCH_BASE_SHA}")"

for file in $(git diff --name-only "${BRANCH_BASE_SHA}" HEAD); do
  recent_count="$(git log origin/main --since="${BRANCH_BASE_DATE}" --oneline -- "${file}" | wc -l)"
  if [ "${recent_count}" -gt 0 ]; then
    echo "BLOCK Gate-1: ${file} 는 base (${BRANCH_BASE_SHA:0:8}) 이후 main 에 ${recent_count} 커밋 추가됨."
    echo "          확인: git log origin/main --since=${BRANCH_BASE_DATE} -- ${file}"
    echo "          rebase 또는 override: PR_SAFETY_ALLOW_STALE_BASE_FILES=\"${file}\""
    exit 1
  fi
done
```

**Override**: `PR_SAFETY_ALLOW_STALE_BASE_FILES="file1 file2"` env. PR body 에 `Stale-base reviewed: <file list>` 라인 필수 (CI 가 secondary 검증).

### §3.2 Gate-2: Post-merge push detection

Branch 의 PR 이 이미 `MERGED` 또는 `CLOSED` 상태면 push 차단.

**Algorithm**:

```bash
PR_NUMBER="$(gh pr list --head "${BRANCH}" --json number --jq '.[0].number' 2>/dev/null)"
if [ -n "${PR_NUMBER}" ]; then
  PR_STATE="$(gh pr view "${PR_NUMBER}" --json state --jq .state)"
  if [ "${PR_STATE}" = "MERGED" ] || [ "${PR_STATE}" = "CLOSED" ]; then
    echo "BLOCK Gate-2: branch '${BRANCH}' 의 PR #${PR_NUMBER} 가 ${PR_STATE} 상태."
    echo "          squash merge 후 추가 커밋은 main 에 도달 안함."
    echo "          신규 PR 필요: git checkout main && git pull && git checkout -b new-branch"
    exit 1
  fi
fi
```

**Override**: 없음 (post-merge push 는 항상 잘못). 신규 branch 만들도록 강제.

### §3.3 Gate-3: force-with-lease 명시형 강제

`--force-with-lease` 단독형은 stale lease honor 위험. `--force-with-lease=<ref>:<sha>` 명시형만 허용.

**Algorithm** (`pre-push` hook 안에서 push 명령 인자 inspect):

```bash
# git pre-push hook 는 cmdline 안 보임 → 대신 agent-side .claude/hooks 에서 검사
# 또는 wrapper alias: git-pp() { git push --force-with-lease="$1:$(git rev-parse $1)" ...; }

# Hook (.claude/hooks/pre_push.sh) 안:
if echo "${PUSH_CMD}" | grep -qE '\-\-force-with-lease[^=]'; then
  echo "BLOCK Gate-3: --force-with-lease 단독형 금지."
  echo "          명시형: git push --force-with-lease=refs/heads/<branch>:<sha-from-fetch>"
  echo "          상세: workflow-pr.md §force-with-lease-must-diff"
  exit 1
fi
```

**Override**: 없음 (silent overwrite 위험은 항상 잘못).

### §3.4 Gate-4: RFC number cross-PR check

새 RFC 파일이 추가될 때, ledger (RFC-0078) 외에 *inflight PR 의 동일 번호* 도 검사.

**Algorithm**:

```bash
NEW_RFCS="$(git diff --name-only --diff-filter=A "${BASE}" HEAD | grep -E '^docs/rfc/RFC-[0-9]{4}-')"
for f in ${NEW_RFCS}; do
  N="$(basename "${f}" | grep -oE 'RFC-[0-9]{4}' | head -1 | cut -d- -f2)"
  # inflight PR 안의 같은 번호
  CONFLICT="$(gh pr list --state open --search "RFC-${N}" --json number,title \
              --jq '.[] | select(.title | contains("RFC-'"${N}"'")) | "#\(.number) \(.title)"' \
              | grep -v "^#${CURRENT_PR_NUMBER:-0} " || true)"
  if [ -n "${CONFLICT}" ]; then
    echo "BLOCK Gate-4: RFC-${N} 가 다른 inflight PR 에 점유됨:"
    echo "${CONFLICT}"
    echo "          재할당: bash scripts/rfc-allocate-next.sh"
    exit 1
  fi
done
```

**Override**: `PR_SAFETY_RFC_COLLISION_ACK="${N}"` (의도적 multi-phase 추가 — README 의 `RFC-EXTEND` 정책 일치).

## §4 SSOT & file layout

```
scripts/
  pr-safety-check.sh                # entry point, runs Gate-1..4 in order
  pr-safety/
    gate_1_stale_base.sh
    gate_2_post_merge.sh
    gate_3_force_lease.sh
    gate_4_rfc_collision.sh
  install-pr-safety-hook.sh         # symlink .git/hooks/pre-push
.claude/hooks/pre_push.sh           # agent-side same script
docs/rfc/.next-number               # (existing, RFC-0078)
```

기존 `pr-rfc-check.sh` 와 별개. RFC 인용 강제 (`pr-rfc-check.sh`) 와 PR 운영 안전 (`pr-safety-check.sh`) 는 직교 surface.

## §5 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 | RFC body merge (이 PR) | Draft → main |
| P2 | `scripts/pr-safety-check.sh` skeleton + Gate-1 (stale-base) | Gate-1 unit test (synthetic stale-base case) PASS |
| P3 | Gate-2 (post-merge) + Gate-3 (force-with-lease) | gh stub test + bash grep test PASS |
| P4 | Gate-4 (RFC collision) + ledger cross-check | inflight PR mock test PASS |
| P5 | `install-pr-safety-hook.sh` + `.claude/hooks/pre_push.sh` 활성화 | 본 RFC override 정책 검증 통과 후 default-on |

P2 ~ P4 는 1 PR 씩 분리. P5 는 *opt-in* 환경 변수 (`PR_SAFETY_HOOK_ENABLED=1`) 로 시작, 4주 telemetry 후 default-on.

## §6 Non-goals

- *Push 전 lint/test* 자동화 (이미 workflow-pr.md §1 에서 *작성자 의무*; 이 RFC 는 push protocol 안전만).
- *RFC 본문 §1 completeness* 검증 (`rfc_enforcer.py` 가 담당).
- *Cross-repo* PR 안전 (이 RFC 는 masc-mcp 한정. kidsnote 등은 별도).
- *Git commit signing* (별도 RFC 후보).

## §7 Risk & rollback

- Gate-1 false positive: file 이 main 에 추가됐어도 의미적으로 동일할 수 있음. → override env 로 release. `Stale-base reviewed:` PR body 라인이 CI 에서 회계.
- Gate-2 가 `gh` rate limit 에 영향: 1 PR push 당 1 호출, 부담 적음. `gh pr list --head` 는 GraphQL 1 query.
- Gate-3 이 의도적 force-push 작업 (e.g. rebase 후) 을 차단: 명시형 `--force-with-lease=<ref>:<sha>` 사용을 강제 — workflow-pr.md 정책과 일치.
- Gate-4 가 ledger (RFC-0078) 와 중복: 의도적 중복. ledger 는 in-worktree atomic, Gate-4 는 cross-worktree race detector. 두 layer 모두 통과해야 RFC 번호 점유.

Rollback: `PR_SAFETY_HOOK_ENABLED=0` 환경 변수로 hook 비활성. 모든 gate 는 idempotent — 별도 mutation 없음.

## §8 Acceptance

- [ ] P1: 본 RFC body merge.
- [ ] P2: Gate-1 stale-base 가 #15862 시나리오 재현 시 BLOCK.
- [ ] P3: Gate-2 post-merge 가 #15784 시나리오 재현 시 BLOCK + Gate-3 force-lease 가 #15618 시나리오 재현 시 BLOCK.
- [ ] P4: Gate-4 가 #15900~15902 동시 inflight 시나리오 재현 시 BLOCK.
- [ ] P5: 4주 telemetry 에서 false-positive < 5%, true-positive ≥ 1 incident 감지 → default-on.

## §9 Open questions

1. (Q1) Gate-3 의 `--force-with-lease` 단독형 금지를 *PR_SAFETY_FORCE_LEASE_BARE_ALLOWED=1* 로 opt-in override 허용할지? **잠정**: 허용 안함 (silent overwrite 는 항상 잘못; 명시형으로 명령 재작성이 항상 가능).

2. (Q2) Gate-1 stale-base 검사를 *file* 단위 vs *line* 단위로? **잠정**: file 단위 (line 단위는 git blame replay 가 expensive — Phase 6+ 고려).

3. (Q3) `.claude/hooks/pre_push.sh` 와 `.git/hooks/pre-push` 가 *두 번* 실행 (agent 가 Bash 로 git push 호출 시 hook 이 또 실행): idempotent 이므로 OK 지만 telemetry 중복. **잠정**: agent-side hook 이 `PR_SAFETY_AGENT_HOOK_RAN=1` env 를 set → git hook 이 skip.
