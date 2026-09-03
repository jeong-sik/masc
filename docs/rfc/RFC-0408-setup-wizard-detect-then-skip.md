---
rfc: "0408"
title: 설치 마법사 — 이미 된 것은 감지하고 묻지 않는다 (모델 소스 × 실행 샌드박스)
status: Draft
created: 2026-09-03
author: Claude Opus 4.8
supersedes: []
superseded_by: null
related: ["0403", "0400", "0405"]
---

## 0. 한 줄 요약

설치 후 masc 를 쓰려면 **모델 소스**(어디서 토큰을 받나)와 **실행 샌드박스**(도구를 어디서 돌리나) 두 축을 정해야 한다. 지금 마법사(`scripts/install.sh --wizard`)는 축 하나(env-key HTTP provider)만 다루고, 나머지는 손으로 `runtime.toml` 을 고쳐야 한다. 마법사를 **감지 후 생략**(detect-then-skip)으로 바꾼다: 이미 된 것은 자동으로 녹색 처리하고 묻지 않으며, **안 된 것만** 한 줄 안내한다. 새 감지를 발명하지 않고 이미 있는 런타임 모듈·probe 레인을 노출한다.

## 1. 문제 — 실측

- 기존 `runtime-wizard-catalog`(main_eio) 는 provider 마다 **HTTP endpoint 를 요구**한다(`bin/main_eio.ml`: "provider uses a CLI transport; install wizard requires an HTTP endpoint"). 그래서 마법사에서 빠지는 것:
  - **subscription CLI 런타임 3종**: Claude Code, Codex, Antigravity — endpoint 없는 CLI transport.
  - **로컬/호스팅 모델 서버**: Ollama, llama-server, vLLM, MLX — endpoint 는 있으나 마법사가 "가용" 판정을 안 함(로컬 프로세스가 떠 있는지).
- **실행 샌드박스**(`sandbox_profile`) 는 마법사가 아예 안 건드린다. keeper 마다 `local` / `docker` / `microvm` / `remote_ssh` 중 하나인데, 손으로 설정해야 한다.
- 결과: "다른 사람이 쉽게 쓰게" 라는 목표에서 가장 마찰이 큰 자리가 이 두 축의 수동 설정이다.

## 2. 기존 machinery (근거 — 새로 만들 것이 적다)

| 조각 | 위치 | 마법사가 쓸 것 |
|---|---|---|
| provider 카탈로그 | `config/runtime.toml`, `runtime-wizard-catalog` subcommand | 모델 소스 목록의 토대 |
| subscription 런타임 auth 모델 | `runtime_claude_code`(subscription.auth_method) / `runtime_codex_app_server`(probe_result) / `runtime_antigravity_home`(oauth 0600 복사) | 계열별 "로그인됨?" 판정 |
| 도달성 probe 레인 | `keeper_capability_probe` / `bin/keeper_capability_probe_cli.ml` | 파일 스키마 파싱 없이 런타임 가용성 검증 |
| 로컬 모델 운영 | `scripts/llama-runtime-pool.sh`, `scripts/masc-sync-ollama-caps.py`, `scripts/llama-server.sh` | 로컬 endpoint 존재/도달 판정 |
| 샌드박스 백엔드 | `sandbox_profile` (`keeper_tool_execute_runtime`), `keeper_microvm_backend`, `keeper_sandbox_docker`, remote_ssh 레인 | 실행 축 선택지 |
| 설치 마법사 골격 | `scripts/install.sh --wizard` (`--provider`/`--api-key`/`--team`/`--dry-run`) | 여기에 두 축을 얹음 |

## 3. 설계 — 두 축, 감지 후 생략

### 3.1 모델 소스 축 (3 버킷)

1. **Subscription CLI** (Claude Code / Codex / Antigravity): masc 가 감싸는 하위 CLI 의 **기존 로그인을 재사용**한다. **토큰을 추출·복사·관리하지 않는다** — "로그인됨?" 만 판정하고 세션·갱신은 그 CLI 에 맡긴다.
   - Claude Code: macOS Keychain `Claude Code-credentials`(account=`$USER`; `CLAUDE_CONFIG_DIR` 설정 시 SHA-256 접미사) 또는 `~/.claude/.credentials.json`. 파일은 Keychain 마이그레이션으로 사라질 수 있으니 **존재만으로 단정 금지**.
   - Codex: `~/.codex/auth.json`(=`CODEX_HOME`) 존재 또는 `runtime_codex_app_server`+probe 레인으로 app-server 를 찌름.
   - Antigravity: 이미 구현된 operator OAuth(0600) 복사 재사용.
   - **가장 드리프트에 강한 검증은 probe 레인**(private auth 스키마 파싱보다).
2. **Cloud API-key provider** (anthropic / openai / glm / deepseek / openrouter …): aider 방식 — env 키 존재를 감지해 자동 녹색. 없으면 `export <PROVIDER>_API_KEY=…` 한 줄 안내(또는 `--api-key-stdin`).
3. **로컬/호스팅 서버** (Ollama / llama-server / vLLM / MLX): localhost endpoint(예: `127.0.0.1:11434`) **도달 여부**로 가용 판정. 안 뜨면 기동 명령 한 줄 안내(`scripts/llama-runtime-pool.sh` 등).

### 3.2 실행 샌드박스 축 (4 선택지)

`sandbox_profile` 을 마법사에서 고르게 한다. 각 백엔드도 **감지**한다:
- `local`: 항상 가능(프로세스 직접).
- `docker`: `docker` 데몬 도달 여부.
- `microvm`: Apple `container` CLI 존재/기동 여부(RFC-0400/0405).
- `remote_ssh`: 대상 endpoint SSH 도달 여부.
감지된 것을 녹색으로, 안 된 것은 준비 명령을 안내. 기본은 `local`(항상 됨).

### 3.3 UX 규칙 (research 근거: Copilot/Codex/aider/opencode)

- **우선순위 사슬**: 명시 env-key → 이미 로그인된 하위 CLI → 대화형 로그인(브라우저 OAuth / device-code). 어느 소스가 선택됐는지 **표시**(stale env 가 좋은 로그인을 가리는 것 방지).
- **zero-config**: 각 축에서 녹색이 정확히 하나면 **묻지 않고** 그걸 쓴다.
- **`/dev/tty` 대화**: `curl … | sh` 는 stdin 이 파이프라 프롬프트가 안 된다 — 프롬프트는 `/dev/tty` 에서 읽고, TTY 없으면 비대화로 감지-only.
- **헤드리스/원격**: 브라우저 OAuth 는 localhost 콜백이 필요해 원격 불가 → device-code(`codex login --device-auth`) 또는 auth 복사.

## 4. 구현 범위

- **바이너리**: `runtime-wizard-catalog` 가 HTTP-endpoint provider 외에 **subscription 런타임·로컬 서버도 emit**(각자의 auth 종류/도달 방식 태그와 함께). endpoint 필수 가정을 제거.
- **install.sh 마법사**: 버킷별 감지 함수(subscription=probe/keychain/파일, env-key=env 존재, 로컬=endpoint 도달) + 샌드박스 감지(docker/microvm/ssh 도달) + 우선순위 사슬 + zero-config + `/dev/tty` 프롬프트.
- **probe 레인 재사용**: 가용성 판정은 파일 파싱이 아니라 `keeper_capability_probe` 로.

### 안 건드리는 것
- 하위 CLI 의 세션·토큰 갱신(그 CLI 소유). 토큰 추출/저장 안 함.
- 기존 `runtime.toml` 스키마(추가 emit 만; 수동 편집 경로 유지).
- 샌드박스 백엔드 구현(RFC-0400/0405). 선택·감지만 추가.

## 5. 안티패턴 (research 근거로 금지)

- **토큰 추출·복사 금지** — macOS Keychain 잠금 우회 취약점 보고. "로그인됨?" 만.
- **private auth 스키마 파싱 의존 금지** — auth.json/keychain 포맷은 준비공개·드리프트. probe 우선, 파일은 보조.
- **존재 ≠ 유효** — `expiresAt` 만료 가능. 갱신은 위임.
- **PATH/rc 자동편집은 옵트인** — 안내 우선.

## 6. 검증

- `install.sh --dry-run` 이 각 축의 감지 결과(녹색/안내)를 찍고, 아무것도 안 쓴다.
- `install-smoke.sh` 에 축별 감지 케이스(로그인 있음/없음, 로컬 endpoint 뜸/안뜸, docker 있음/없음) 추가.
- probe 레인으로 "선택된 런타임이 실제 도달 가능한가" 를 마법사 끝에서 1회 검증.

## 7. 미해결 / 확인 필요

- `runtime_antigravity_home` 의 `oauth_source` 가 가리키는 구체 Antigravity 파일 경로(호출부 확인).
- Codex/Claude 의 깨끗한 "status exit code" 부재 — probe 레인이 유일하게 안정적인 검증인지 실측.
- 로컬 서버(vLLM/MLX)의 정확한 기본 포트·health 경로(공식 문서 재확인).
