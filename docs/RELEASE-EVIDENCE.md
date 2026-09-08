---
status: runbook
---

# Release Evidence

> Version source: [`dune-project`](../dune-project)
> Updated: 2026-09-08

`masc`의 release/readiness 상태를 말할 때는 문구보다 증거가 먼저여야 한다.
기본 증거 형식은 release-evidence bundle이며, 최소한 아래 항목이 함께 있어야 한다.

## Required Bundle

- artifact install smoke: release-shaped binary를 설치 경로에서 직접 실행해 `--version`이 맞는지 확인
- local boot + `/health`: isolated base path에서 서버 부팅 후 health payload 저장
- MCP handshake: `initialize` + `tools/list` raw capture 저장
- repo workspace collaboration read path: `masc_status` raw capture 저장
- dashboard read paths: `/api/v1/dashboard/briefing`, `/api/v1/dashboard/project-snapshot` raw capture 저장
- quantitative readiness: `docs/PRODUCTION-READINESS-GATES.md`의 release artifact, keeper turn evidence, performance SLO, agent core pin/boundary gate 결과를 함께 첨부
- raw evidence: headers/body/json 정규화본 + `server.log`

이 bundle이 없으면 최신 release/main에 대해 release-ready 또는 production-ready claim을 하지 않는다.

## Canonical Commands

기본 smoke:

```bash
scripts/release-binary-smoke.sh _build/default/bin/main_eio.exe
```

evidence bundle 생성:

```bash
scripts/release-evidence.sh _build/default/bin/main_eio.exe .release-evidence/local-release-evidence.md
```

위 명령은 이미 빌드된 바이너리에 사용합니다. 코딩 에이전트는 로컬 빌드 대신
`Release` workflow의 `workflow_dispatch`로 현재 브랜치의 바이너리와 증거를 생성합니다.

## One-commit candidate verification

태그를 만들기 전 다음 명령으로 검증할 브랜치의 한 커밋을 선택합니다.

```bash
gh workflow run release-candidate.yml --ref main
```

이 실행은 같은 커밋의 기존 `CI`, 전체 `Test`, 4개 플랫폼 `Release` 설치
검증과 최종 배포 자산 조립을 함께 호출합니다. 부분 suite를 선택하는
입력은 없습니다. 기존
`test/ci-known-failures.txt` 정책은 그대로 적용되므로 전체 Test 통과를
모든 알려진 결함의 해결로 해석하지 않습니다.

`candidate-verification-<sha>-attempt-<n>` artifact는 커밋과 세 결과를 기록합니다.
실패·취소·건너뜀은 성공으로 기록하지 않습니다. 재실행 시 해당 job의
중간 자산을 교체하며, 최종 배포 묶음과 receipt는 attempt별로 보존합니다. 공개 Release는 생성하지
않으며, 태그 push의 게시 경로만 유지합니다. 새 main 커밋을 태그할 때는
그 커밋으로 다시 실행해야 합니다. 과거 freeze 브랜치의 초록 결과를
현재 main의 증거로 재사용하지 않습니다.

## Workflow Contract

- [`Release`](../.github/workflows/release.yml)는 macOS ARM64/x64와 Linux ARM64/x64를 모두 빌드한다. 각 job은 `release-evidence-<arch>.md`와 raw captures를 `masc-<arch>` Actions artifact에 업로드한다.
- 같은 job은 `scripts/install-smoke.sh dist <arch>`로 checksum 기반 설치, 설정 seed, 설치된 서버의 health와 대시보드를 검증한다. Linux는 새 Ubuntu 24.04 container에서도 반복한다.
- `workflow_dispatch`는 Actions artifact를 생성한다. `v*` 태그 push는 네 target 성공 후 공개 Release 자산과 `SHA256SUMS`도 게시한다.
- 일반 `CI`의 main push에서 release evidence artifact가 생성된다고 가정하지 않는다. 증거는 검증할 커밋의 `Release` 실행에서 가져온다.
- release evidence는 docs-only narrative가 아니라, 실제 build artifact에서 재생성 가능한 산출물이어야 한다.

## What This Proves

- 현재 build artifact가 설치 가능한 모양인지
- 실제 binary가 부팅되고 `/health`를 제공하는지
- MCP public surface가 최소 handshake를 만족하는지
- dashboard read model이 최소 조회 경로에서 깨지지 않는지
- `docs/PRODUCTION-READINESS-GATES.md` 결과가 첨부된 경우, keeper turn evidence chain과 agent core pin/boundary가 정량 기준을 만족하는지

## What This Does Not Prove

- 외부 배포 환경의 auth/secret/network 설정
- env-specific deployment smoke
- operator bearer-token workflow의 현장 구성
- 첨부되지 않은 performance SLO 또는 keeper continuity scenario

이 부분은 별도 deploy/runbook evidence가 있어야 한다. 즉 local release bundle은 baseline proof이고, environment proof를 대체하지 않는다.
