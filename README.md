# MASC

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.4-orange.svg)](https://ocaml.org/)
[![agent_sdk](https://img.shields.io/badge/agent__sdk-%3E%3D%200.207.5-blue.svg)](https://github.com/jeong-sik/oas)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> **개인용 인프라**  
> MASC는 1인 개발 워크플로우용 도구다. 프로덕션 SLA, 외부 하드웨어 호환성, SemVer 기반 API 안정성을 보장하지 않는다.

MASC는 OCaml 5.x + Eio 기반의 다중 AI 코딩 에이전트 워크스페이스 오케스트레이션 도구다. 같은 저장소를 동시에 작업하는 여러 에이전트가 충돌하지 않도록 턴, 락, 작업자 소유권, 상태, 하트비트를 조율한다.

---

## Overview

```
┌─────────────────────────────────────────────┐
│  Client (Dashboard, Slack, Discord, Chat)   │
└───────────────────┬─────────────────────────┘
                    │ HTTP / WebSocket / MCP
┌───────────────────▼─────────────────────────┐
│  MASC                                       │
│  - Channel Gate                             │
│  - Phase & Turn FSM                         │
│  - Single-flight admission                  │
│  - Workspace, board, task, claim state      │
└───────────────────┬─────────────────────────┘
                    │ OAS bridge
┌───────────────────▼─────────────────────────┐
│  OAS / agent_sdk (single-provider runtime)  │
│  - Tool dispatch, context, retry            │
└─────────────────────────────────────────────┘
```

- **MASC**는 "언제, 어떤 에이전트 프로필로 턴을 실행할지"를 스케줄링하고 동시성을 제어하며, 다중 메시지 채널(Surface)을 조율한다.
- **OAS / agent_sdk**는 MASC가 선택한 단일 프로바이더 호출의 순수 실행만 담당한다.

---

## What it does

- **Multi-channel input**: Dashboard, Discord, Slack, Gate를 `Surface` 타입으로 추상화해 턴을 트리거한다.
- **Channel Gate**: 외부 연동 커넥터는 `/api/v1/gate/message`로 메시지를 밀어 넣어 턴을 시작한다.
- **Single-flight admission**: 동일 Keeper에 대해 동시에 하나의 Active Turn만 허용한다.
- **Phase & Turn FSM**: Keeper 라이프사이클과 개별 턴 실행 흐름을 상태 머신으로 관리한다.
- **Workspace state**: 파일 기반 보드, 태스크, 클레임 상태를 관리한다.
- **Local dashboard**: 웹 기반 모니터링 및 명령 패널을 제공한다.

---

## Requirements

- OCaml >= 5.4
- opam >= 2.0
- dune >= 3.22
- agent_sdk >= 0.207.5

의존성 전체는 [`masc.opam`](masc.opam)을 본다.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash
```

현재 제공되는 prebuilt 바이너리:

- macOS arm64
- Linux x86_64

다른 플랫폼은 소스 빌드 또는 GitHub Actions 릴리즈를 추적한다.

---

## Build & Run

```bash
# 외부 의존성 핀 및 설치
scripts/opam-pin-external-deps.sh
opam install . --deps-only

# 빌드
scripts/dune-local.sh build bin/main_eio.exe

# 실행
scripts/run-local.sh --target-dir "$PWD"
```

`scripts/dune-local.sh`는 worktree 간 동시 빌드 충돌을 막기 위해 글로벌 락 파일(`/tmp/me-dune-local.lock`)을 사용한다.

### Run modes

- **`scripts/start-loopback.sh`**: 고정 포트 `8935`로 기동. Keeper 스케줄러를 끄고 순수 로컬 Mock 디버깅용으로 사용한다.
- **`scripts/run-local.sh --target-dir /path`**: 지정한 폴더 기준으로 격리 기동. 포트는 폴더 경로 해시를 기반으로 `9100-9999` 범위에서 자동 할당한다.
- **`./start-masc.sh --http`**: Keeper 스케줄러를 포함한 전체 런타임을 기동한다.

---

## Test

```bash
# 유닛 테스트
make test

# 전체 CI suite
make ci

# 릴리즈 증적 수집
make release-evidence
```

---

## Documentation

- [`docs/OAS-MASC-BOUNDARY.md`](docs/OAS-MASC-BOUNDARY.md): MASC와 OAS 간 경계
- [`docs/keeper-turn-lifecycle.md`](docs/keeper-turn-lifecycle.md): 턴 생명주기
- [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md): 대시보드 인증
- [`docs/RELEASE-EVIDENCE.md`](docs/RELEASE-EVIDENCE.md): 릴리즈 smoke 절차
- Dashboard routes: `dashboard#monitoring?section=journey`, `dashboard#command?section=operations`, `dashboard#connectors?section=connector-status`, `dashboard#workspace?section=verification`

---

## License

MIT. 아무 보증 없이 "있는 그대로" 제공된다.
