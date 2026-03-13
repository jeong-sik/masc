# Release Roadmap

`masc-mcp`의 release/versioning/milestone 운영 SSOT입니다.

기준 시점:
- current release SemVer: `2.86.0`
- release automation: tag push `v*` -> [`.github/workflows/release.yml`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/chore-release-roadmap-milestones/.github/workflows/release.yml)
- version bump script: [`scripts/bump-version.sh`](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/chore-release-roadmap-milestones/scripts/bump-version.sh)

## Why Now

최근 PR가 짧은 시간 안에 많이 쌓이면서, "최소 기능이 되는가"와 "어떤 변경이 어느 release lane에 들어가야 하는가"를 분리해서 관리할 필요가 생겼다.

이 문서는 세 가지를 고정한다.

1. 어떤 변경이 patch/minor/major 인가
2. 어떤 milestone만 동시에 열어둘 것인가
3. release 전에 무엇이 green 이어야 하는가

## Version Layers

`masc-mcp`는 버전을 세 층으로 본다.

1. Release SemVer
   - SSOT: `dune-project`
   - 동기화 대상: `README.md` badge, `masc_mcp.opam`, `CHANGELOG.md`
   - 변경 명령: `./scripts/bump-version.sh <x.y.z>`
2. Protocol Version
   - SSOT: MCP/A2A/health header 및 protocol matrix
   - release SemVer와 독립적이다
3. Artifact Schema Version
   - report/proof/cache JSON 내부 `schema_version`
   - release와 별도로 상승 가능하다

즉, `2.86.1`을 올린다고 MCP protocol version을 같이 올리는 것은 아니다.

## SemVer Rules

### Patch: `x.y.Z`

다음만 patch에 넣는다.

- CI, PR hygiene, asset regeneration
- regression fix
- 문서 보강
- 내부 refactor 중 public surface를 바꾸지 않는 것
- compatibility alias 유지 상태에서의 안정화

patch에 넣지 말 것:

- canonical MCP tool 이름 변경
- deprecated alias 제거
- dashboard/HTTP contract 의미 변경

### Minor: `x.Y.0`

다음을 minor로 본다.

- 새로운 public MCP surface
- dashboard read model/semantics 확장
- deprecated alias 도입 또는 제거 예고
- operator/command-plane contract 추가
- mainline 구조 분할이 사용자-visible 경계에 닿는 경우

### Major: `X.0.0`

다음을 major 후보로 본다.

- MCP client가 코드를 바꿔야 하는 contract break
- dotted canonical tool / underscore alias 정책의 대규모 파기
- release note만으로 흡수할 수 없는 protocol incompatibility

현재는 `v3`를 열지 않고, `2.x` minor train 안에서 관리한다.

## Milestone Policy

동시에 유지하는 open milestone은 최대 3개다.

1. `current patch`
2. `next minor`
3. `next-next minor`

운영 규칙:

- `main`에 바로 들어갈 수 있는 PR만 patch milestone 후보로 둔다
- stacked draft PR는 parent branch가 `main`으로 정리되기 전까지는 release candidate로 간주하지 않는다
- milestone은 issue bucket이 아니라 release train이다
- milestone close 조건은 "관련 PR 머지"가 아니라 "release gate 충족"이다

## Current Rolling Milestones

### `v2.86.1` Stabilization

목표:
- `2.86.0` 직후의 CI/contract/dashboard asset drift 정리
- release metadata와 changelog 정합성 유지

포함 기준:
- patch-only change
- surface break 없음

exit criteria:
- required CI green
- `CHANGELOG.md` patch notes 정리
- `./scripts/bump-version.sh 2.86.1`
- tag `v2.86.1`

### `v2.87.0` Managed-Agent Surface Cleanup

목표:
- managed-agent / capability registry / deprecated alias cleanup
- public MCP surface를 더 명확히 분리

현재 대표 PR:
- `#960` `refactor(mcp): split managed-agent surface and remove deprecated aliases`

exit criteria:
- `main` target PR only
- migration/deprecation note 존재
- no hidden contract regression in `tools/list`, `tools/call`, operator surface

### `v2.88.0` Dashboard Truth Consolidation

목표:
- observability/mission/dashboard truth surface를 mainline 기준으로 정리
- stacked dashboard drafts를 `main` 기준으로 다시 연결

현재 후보 PR:
- `#961` `feat(dashboard): make observability truth more explicit`
- `#962` `feat(dashboard): make mission truth more explicit`

주의:
- 현재 `#961`, `#962`는 stacked draft다
- milestone에는 묶되, release candidate 상태는 아니다

exit criteria:
- `main` 기준 rebase 또는 replay 완료
- dashboard assets / PR hygiene / contract harness green
- operator-facing copy와 truth source가 SSOT 문서와 일치

## PR Triage Rules For Milestones

PR를 milestone에 넣기 전 체크:

1. base branch가 `main`인가
2. required CI가 현재 branch head 기준으로 green 가능한가
3. patch인지 minor인지 설명 가능한가
4. changelog line 한 줄로 요약 가능한가

다음 중 하나라도 아니면 release train에 올리지 않는다.

- stacked branch only
- unrelated history replay 대기
- CI 의미 불명
- contract drift unresolved

## Release Checklist

release 직전 최소 체크:

```bash
git fetch origin main --tags
./scripts/bump-version.sh <x.y.z>
dune build --root .
gh pr list --state open
gh api repos/jeong-sik/masc-mcp/milestones
git tag v<x.y.z>
git push origin v<x.y.z>
```

release note 최소 항목:

- Added
- Changed
- Deprecated
- Fixed

## Immediate Next Action

현재 우선순위:

1. `v2.86.1` stabilization 여부 결정
2. `#960`를 `v2.87.0` train으로 취급
3. `#961`, `#962`는 `v2.88.0` dashboard train으로 유지하되, `main` 기준 replay 전에는 release candidate로 취급하지 않음
