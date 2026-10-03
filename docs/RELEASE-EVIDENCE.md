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
허용된 `release/v*` 브랜치 또는 태그에서 `Release` workflow의 `workflow_dispatch`로
바이너리와 증거를 생성합니다.

## One-commit candidate verification

[Release freeze](guides/RELEASE-FREEZE.md)에 따라 포함 범위와 후보를 먼저 고정합니다.
고정 후에는 출시 차단 결함만 선별 수리하며, main 갱신을 이유로 후보에 병합하지 않습니다.
후보 수리와 다음 버전의 기능·CI 개선은 별도 스택으로 진행합니다.

후보를 고정하기 전에 포함 수리, 테스트 변경, 릴리스 노트와 본문을 대조합니다.
후보 원장은 source SHA·ref·포함 변경·소스 리뷰 범위·run ID/attempt·산출물 identity를
연결합니다. 후보를 교체하면 이전 run, 새 SHA, 변경 범위, 교체 이유와 재검증 범위를
같은 원장에 남깁니다. 취소 이유가 미확인이면 미확인으로 기록하며, 모든 취소를 낭비로
세거나 취소 금지·추가 승인 절차를 만들지 않습니다.

태그를 만들기 전 검증할 release 브랜치의 한 커밋을 선택합니다. 아래 이름은 실제
release 브랜치로 치환합니다. 현재 workflow는 `release/v*` 브랜치 또는 `v*` 태그만 받습니다.

```bash
gh workflow run release-candidate.yml --ref release/vX.Y.Z
```

이 실행은 같은 커밋의 `Full Check(full-check.yml)`, 전체 `Test`, 4개 플랫폼 `release-build.yml` 설치
검증과 최종 배포 자산 조립을 함께 호출합니다. 부분 suite를 선택하는
입력은 없습니다. 전체 Test는 루트 `@runtest`를 한 번 실행하고 Dune의 종료 코드로
판정합니다. 실패를 허용하는 목록이나 별도 재컴파일 경로는 없습니다.

`candidate-verification-<sha>-attempt-<n>` artifact는 커밋과 세 결과를 기록합니다.
실패·취소·건너뜀은 성공으로 기록하지 않습니다. 재실행 시 해당 job의
중간 자산을 교체합니다. 배포 묶음은 run별로 보존해 실패한 job만 재실행해도
이전에 성공한 설치 산출물을 사용하며, receipt는 attempt별로 보존합니다. 공개 Release는 생성하지
않습니다. 공개 게시에는 기존 버전 태그를 대상으로 하는 명시적 `publish=true` dispatch와
해당 커밋의 최신 성공 Full RC를 지정하는 `rc_run_id`가 필요합니다.
게시 단계는 최신 RC attempt의 검증 receipt와 같은 run의 성공한 배포 묶음을 내려받아 SHA-256을 확인하고,
검증된 파일과 RC에서 길이·날짜를 검사한 릴리즈 본문을 그대로 게시합니다. 빌드와 테스트를 반복하지 않습니다. 새 커밋을 태그할 때는
그 커밋으로 다시 실행해야 합니다. 과거 freeze 브랜치의 초록 결과를
현재 main의 증거로 재사용하지 않습니다.

## Workflow Contract

- [`Release build and installation`](../.github/workflows/release-build.yml)는 macOS ARM64/x64와 Linux ARM64/x64를 모두 빌드한다. 각 job은 `release-evidence-<arch>.md`와 raw captures를 `masc-<arch>` Actions artifact에 업로드한다.
- 같은 job은 `scripts/install-smoke.sh dist <arch>`로 checksum 기반 설치, 설정 seed, 설치된 서버의 health와 대시보드를 검증한다. Linux는 새 Ubuntu 24.04 container에서도 반복한다.
- [`Release`](../.github/workflows/release.yml)는 기존 `v*` 태그에서 `rc_run_id`와 `publish=true`를 받아 검증된 RC 자산과 `SHA256SUMS`를 게시한다. `publish=false`는 같은 검증과 다운로드만 수행한다. 태그 push 자체는 자동 게시를 시작하지 않는다.
- 실패한 RC, 다른 커밋, 더 최신 RC가 있는 경우, 만료 또는 누락된 artifact, 체크섬 불일치는 게시를 거부한다. 배포 묶음이 만료됐다면 같은 커밋의 RC를 다시 검증해야 한다.
- 실제 발행은 출시 담당이 현재 운영자 결정, workflow 활성 상태와 고정 SHA의 검증을 확인한 뒤 실행한다. 이 문서의 후보 검증 명령은 활성화·태그·발행을 요청하거나 승인하지 않는다.
- 일반 `CI`의 main push에서 release evidence artifact가 생성된다고 가정하지 않는다. 증거는 검증할 커밋의 `Release Candidate Verification` 실행에서 가져온다.
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
