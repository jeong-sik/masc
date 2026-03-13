# v2.86.1 Stabilization Guide

`masc-mcp`의 현재 patch stabilization 운영 기준입니다.

기준 시점:
- current release SemVer: `2.86.0`
- release automation: tag push `v*` -> [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- version bump script: [`scripts/bump-version.sh`](../scripts/bump-version.sh)

## Goal

`v2.86.1`은 새 기능 release가 아니라, `2.86.0` 직후 mainline을 안전하게 굳히는 patch release입니다.

이번 stabilization의 목표:
- required CI를 다시 일관되게 green으로 유지
- MCP/dashboard/HTTP contract drift를 patch 범위 안에서 정리
- release metadata와 changelog를 현재 mainline truth에 맞춤

## What Goes In

`v2.86.1`에는 다음만 넣습니다.

- build, CI, PR hygiene, asset regeneration fixes
- regression fix
- docs-only clarification
- public contract를 넓히지 않는 compatibility fix
- internal refactor 중 public surface 의미를 바꾸지 않는 것

## What Stays Out

이번 patch lane에는 다음을 넣지 않습니다.

- 새로운 public MCP surface
- canonical tool naming 정책 변경
- deprecated alias 제거 같은 migration-heavy change
- dashboard information architecture를 다시 짜는 큰 UX 변경
- stacked feature branch replay

## Candidate Rule

`v2.86.1` candidate로 올리기 전 체크:

1. base branch가 `main`인가
2. required CI를 현재 head 기준으로 green으로 만들 수 있는가
3. changelog 한 줄로 `Fixed` 또는 `Changed`에 설명 가능한가
4. patch 범위를 넘는 migration note가 필요하지 않은가

위 조건을 만족하지 않으면 다음 minor train으로 넘깁니다.

## Exit Criteria

release 전 최소 조건:

- required CI green
- `CHANGELOG.md`에 `2.86.1` 항목 정리
- `./scripts/bump-version.sh 2.86.1`
- `dune build --root .`
- tag `v2.86.1`

## Operator Checklist

release 직전 점검:

```bash
git fetch origin main --tags
gh pr list --state open
dune build --root .
./scripts/bump-version.sh 2.86.1
git tag v2.86.1
git push origin v2.86.1
```

## Immediate Rule

현재 `v2.86.1` lane은 “mainline stabilization only”로 취급합니다.

- docs or compatibility follow-up: 포함 가능
- new dashboard truth lane or future roadmap planning: 제외
- future minor planning은 별도 docs PR에서 다룹니다
