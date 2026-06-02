# Prepare v2.87.0 Minor Release

`masc-mcp`의 현재 release closeout 기준입니다.

기준 시점:
- current release SemVer: `2.86.0`
- next release target: `2.87.0`
- release automation: tag push `v*` -> [`.github/workflows/release.yml`](../../.github/workflows/release.yml)
- version bump script: [`scripts/bump-version.sh`](../../scripts/bump-version.sh)

## Goal

`v2.87.0`은 `2.86.0` 이후 `main`에 이미 들어간 public-surface cleanup과 dashboard truth line을 정직하게 반영하는 minor release입니다.

이번 release의 목표:
- managed-agent / hidden tool surface cleanup을 minor train으로 정식 반영
- dashboard observability truth line과 autonomy truth compatibility를 release note에 반영
- governance/H2/auth/baseline follow-up을 같은 release closeout으로 묶기
- release metadata와 changelog를 current `main` truth에 맞춤

## What Goes In

`v2.87.0`에는 다음을 넣습니다.

- 사용자-visible 경계에 닿는 cleanup
- dashboard read-model / truth 표현 확장
- H2 / auth / governance hardening follow-up
- current `main`에 이미 들어간 minor-grade refactor와 compatibility fix

## What Stays Out

이번 minor lane에는 다음을 넣지 않습니다.

- protocol-major break
- v3 migration
- stacked feature branch replay
- unrelated experimental feature train

## Candidate Rule

`v2.87.0` candidate로 올리기 전 체크:

1. base branch가 `main`인가
2. required CI를 현재 head 기준으로 green으로 만들 수 있는가
3. changelog에서 `Changed` / `Fixed`로 release note를 설명 가능한가
4. protocol-major migration note가 필요하지 않은가

위 조건을 만족하지 않으면 다음 major 또는 다음 minor train으로 넘깁니다.

주의:
- 이번 release는 protocol-major break는 아니지만, hidden/deprecated surface나 legacy governance HTTP에 기대던 클라이언트에게는 upgrade note가 필요할 수 있습니다.
- 즉 `major migration note`는 아니어도, `minor upgrade note`는 release note에 포함하는 것을 기본으로 봅니다.

## Exit Criteria

release 전 최소 조건:

- required CI green
- `CHANGELOG.md`에 `2.87.0` 항목 정리
- `./scripts/bump-version.sh 2.87.0`
- `dune build --root .`
- tag `v2.87.0`

release automation은 tag push 이후에 동작합니다. 즉 수동 단계는 `bump-version`과 `git tag`까지이고, release workflow는 `git push origin v2.87.0` 뒤에 자동으로 이어집니다.

## Operator Checklist

release 직전 점검:

```bash
git fetch origin main --tags
gh pr list --state open
dune build --root .
./scripts/bump-version.sh 2.87.0
git tag v2.87.0
git push origin v2.87.0
```

## Included Mainline Changes

현재 `v2.87.0` closeout에 포함되는 대표 변경:

- `#960` managed-agent surface split and deprecated alias cleanup
- `#965` governance HTTP read-only 정리
- `#966` H2 write route tool auth 정렬
- `#967` legacy task alias task-op 분류 복구
- `#968` observability truth on main
- `#970` team-session / auth baseline compatibility 복구
- `#971` board patrol noise 억제
- `#974` autonomy truth compatibility follow-up
- `#976` dead hidden tool surface prune

## Upgrade Note Policy

`v2.87.0` release note에는 최소한 다음을 명시합니다.

- managed-agent / hidden tool surface cleanup이 mainline에 반영되었음
- governance HTTP surface는 current read-only model을 기준으로 본다는 점
- dashboard truth line 확장으로 operator-facing wording이 더 명시적으로 바뀌었다는 점
