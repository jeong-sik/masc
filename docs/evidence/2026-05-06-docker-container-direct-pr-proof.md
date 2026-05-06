# Evidence Record - Docker Container Direct Git PR Proof

## 공통 헤더

- 날짜(ISO8601): `2026-05-06T19:17:02+09:00`
- 작성자: keeper docker container direct git proof
- 결정 ID: `docker-container-direct-pr-proof-20260506-103414`
- 적용 대상: `keeper/docker-container-direct-pr-proof-20260506-103414`, PR `#13541`
- 결정 상태: 초안 PR proof record

## 근거 (Evidence)

| 항목 | 출처 (파일:줄 또는 명령) | 확인일시 | 신뢰도 | 비고 |
|---|---|---|---|---|
| PR head branch exists | `git rev-parse --abbrev-ref HEAD` -> `keeper/docker-container-direct-pr-proof-20260506-103414` | 2026-05-06T19:17:02+09:00 | High | 로컬 proof worktree에서 확인 |
| Observed PR head before this evidence refresh | `git rev-parse HEAD` -> `2638eaa871bc501eabc00009bb1cf5be2b55ee21` | 2026-05-06T19:17:02+09:00 | High | live PR head was checked before this doc-only refresh commit |
| GitHub PR metadata | `gh pr view 13541 --json headRefName,headRefOid,isDraft,mergeable,mergeStateStatus` | 2026-05-06T19:17:02+09:00 | High | draft PR; GitHub mergeability was still recalculating |
| Evidence file is the only PR payload | `git diff --name-only origin/main...HEAD` -> `docs/evidence/2026-05-06-docker-container-direct-pr-proof.md` | 2026-05-06T19:17:02+09:00 | High | proof-only PR 범위 확인 |

## 검증 (Verification)

Commands run from the proof worktree:

```text
$ git status --short --branch
## keeper/docker-container-direct-pr-proof-20260506-103414...origin/keeper/docker-container-direct-pr-proof-20260506-103414

$ git diff --name-only origin/main...HEAD
docs/evidence/2026-05-06-docker-container-direct-pr-proof.md

$ gh pr view 13541 --json headRefName,headRefOid,isDraft,mergeable,mergeStateStatus
{"headRefName":"keeper/docker-container-direct-pr-proof-20260506-103414","headRefOid":"2638eaa871bc501eabc00009bb1cf5be2b55ee21","isDraft":true,"mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN"}
```

## 불확실성 (Uncertainty)

- This record verifies the PR/worktree/git evidence visible after the container-created proof branch was published. It does not replay the original container session stdout.
- The PR head can advance after this record is refreshed; use the live `gh pr view` command above as the currentness check.
- If the proof requirement needs full container stdout, attach the original container transcript or rerun the direct-git flow with stdout capture.

## 적용범위 (Scope)

- Impact: documentation-only evidence record under `docs/evidence/`.
- Excluded: production code, CI workflow, runtime behavior.
- Rollback condition: delete this evidence record or supersede it with a fuller transcript-backed evidence record.

## 다음 액션

- Keep PR `#13541` draft until the operator decides whether this proof-only record is sufficient or wants a full rerun with captured container stdout.
