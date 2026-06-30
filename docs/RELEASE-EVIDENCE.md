---
status: runbook
last_verified: 2026-06-30
code_refs:
  - lib/mcp_server.ml
  - lib/keeper/
  - lib/keeper/keeper_runtime.ml
---

# Release Evidence

> Current package version: v0.19.55
> Updated: 2026-06-30

`masc`의 release/readiness 상태를 말할 때는 문구보다 증거가 먼저여야 한다.
기본 증거 형식은 release-evidence bundle이며, 최소한 아래 항목이 함께 있어야 한다.

## Required Bundle

- artifact install smoke: release-shaped binary를 설치 경로에서 직접 실행해 `--version`이 맞는지 확인
- local boot + `/health`: isolated base path에서 서버 부팅 후 health payload 저장
- MCP handshake: `initialize` + `tools/list` raw capture 저장
- repo workspace collaboration read path: `masc_status` raw capture 저장
- dashboard read paths: `/api/v1/dashboard/briefing`, `/api/v1/dashboard/namespace-truth` raw capture 저장
- quantitative readiness: `docs/PRODUCTION-READINESS-GATES.md`의 release artifact, keeper turn evidence, performance SLO, OAS pin/boundary gate 결과를 함께 첨부
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

make shortcut:

```bash
make release-evidence
```

## Workflow Contract

- `CI` workflow의 `main` push는 `release-evidence-main` artifact를 업로드한다.
- `Release` workflow는 `release-evidence-<arch>.md`와 raw captures를 release artifact에 같이 붙인다.
- release evidence는 docs-only narrative가 아니라, 실제 build artifact에서 재생성 가능한 산출물이어야 한다.

## What This Proves

- 현재 build artifact가 설치 가능한 모양인지
- 실제 binary가 부팅되고 `/health`를 제공하는지
- MCP public surface가 최소 handshake를 만족하는지
- dashboard read model이 최소 조회 경로에서 깨지지 않는지
- `docs/PRODUCTION-READINESS-GATES.md` 결과가 첨부된 경우, keeper turn evidence chain과 OAS pin/boundary가 정량 기준을 만족하는지

## What This Does Not Prove

- 외부 배포 환경의 auth/secret/network 설정
- env-specific deployment smoke
- operator bearer-token workflow의 현장 구성
- 첨부되지 않은 performance SLO 또는 keeper continuity scenario

이 부분은 별도 deploy/runbook evidence가 있어야 한다. 즉 local release bundle은 baseline proof이고, environment proof를 대체하지 않는다.
