---
rfc: "0408"
title: 설치 마법사 — 이미 된 것은 감지하고 묻지 않는다 (모델 소스 × 실행 샌드박스)
status: Implemented
created: 2026-09-03
author: Claude Opus 4.8
supersedes: []
superseded_by: null
related: ["0403", "0400", "0405"]
---

## 0. 한 줄 요약

설치 후 masc 를 쓰려면 **모델 소스**(어디서 토큰을 받나)와 **실행 샌드박스**(도구를 어디서 돌리나) 두 축을 정해야 한다. 지금 마법사(`scripts/install.sh --wizard`)는 축 하나(env-key HTTP provider)만 다루고, 나머지는 손으로 `runtime.toml` 을 고쳐야 한다. 마법사를 **감지 후 생략**(detect-then-skip)으로 바꾼다: 이미 된 것은 자동으로 녹색 처리하고 묻지 않으며, **안 된 것만** 한 줄 안내한다. 새 감지를 발명하지 않고 이미 있는 런타임 모듈·probe 레인을 노출한다.

## 0.1 구현 완료 (2026-09-03, PR #32852·57·68·84·97·32901·32903·32907·32914)

구현하며 **원안이 틀린 곳을 실측으로 바로잡았다** — 상세는 각 절에 반영. 요약:

- **모델 소스 축**: catalog 견고화(#32852) → subscription 런타임 emit(#32857) → 로컬 서버 도달성 감지(#32868) → subscription 로그인 probe `masc runtime-probe`(#32897) → auto-default(#32903, TTY) → zero-config 비-TTY auto-select(#32914). 전부 구현·테스트.
- **실행 샌드박스 축**: 원안(§3.2)은 "마법사에서 고르고 쓴다(local 기본)"를 가정했으나, 샌드박스는 **per-keeper 이고 전역 기본 surface 도 `Local` 변형도 없다**(실측). 그래서 **감지·안내만** 한다(#32884). 선택을 쓰려면 새 전역 surface(별도 RFC)가 필요 — §3.2·§7 참조.
- **원안 밖 추가**: `masc mcp-config`(#32907) — MCP 클라이언트 연결을 한 블록으로. 마법사가 모델·샌드박스를 잡아도 "여러 에이전트가 MCP 로 공유"에는 클라이언트 수동 배선이 남던 마찰을 없앰.
- **문서**: README "First-run setup" + "MCP client setup" 갱신(#32901, #32907).

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

### 3.2 실행 샌드박스 축 — 감지·안내만 (원안 수정, 실측 근거)

> **원안 수정.** 초안은 "`sandbox_profile` 을 마법사에서 고르게 한다, 기본 `local`" 이었다. 구현 중 실측으로 이 전제가 틀린 것을 확인했다:
> - 샌드박스는 **per-keeper** 다 — `.masc/config/keepers/<name>.toml` 의 `[keeper] sandbox_profile`. 부재는 에러(accessor 가 raise). **전역 기본 surface 가 없다**(runtime.toml 에 `[sandbox]` 없음, 프로필 선택 env 없음).
> - 타입은 `Docker | Micro_vm | Remote_ssh` 셋뿐(`keeper_types_profile_sandbox.ml`). **`Local` 변형이 없다** — `"local"` 은 별도 in-process 레인(`keeper_tool_in_process_runtime.ml`)이 `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` 하에 처리하는, presets/README 에 `WORKAROUND:` 로 문서화된 우회.
> - keeper 는 `--team <preset>` 가 각자 `sandbox_profile` 을 지니고 온다.
>
> 즉 install 마법사가 "샌드박스 선택"을 **쓸 자리가 없다**. 전역 surface 를 신설하는 것은 manifest 가 경계하는 Gate 추가라, 하지 않았다.

그래서 마법사는 호스트가 제공 가능한 백엔드를 **감지·표시만** 한다(#32884). 쓰기 없음:
- `docker`: `command -v docker` → `docker info`(데몬 없으면 즉시 실패) → available / installed, daemon not responding / not installed.
- `microvm (apple container)`: macOS 에서 `container` CLI 존재 → available / not installed / macOS only.
- `remote_ssh`: transport-only 라 호스트 감지 무의미 → runtime.toml `[exec.ssh.endpoints]` 로 안내.

그리고 **선택이 실제로 이뤄지는 자리**(per-keeper `sandbox_profile`, 또는 `--team <preset>`)를 알려준다 — 존재할 수 없는 마법사 프롬프트를 찾아 헤매지 않도록.

### 3.3 UX 규칙 (research 근거: Copilot/Codex/aider/opencode)

- **우선순위 사슬**: 명시 env-key → 이미 로그인된 하위 CLI → 대화형 로그인(브라우저 OAuth / device-code). 어느 소스가 선택됐는지 **표시**(stale env 가 좋은 로그인을 가리는 것 방지).
- **zero-config**: 각 축에서 녹색이 정확히 하나면 **묻지 않고** 그걸 쓴다.
- **`/dev/tty` 대화**: `curl … | sh` 는 stdin 이 파이프라 프롬프트가 안 된다 — 프롬프트는 `/dev/tty` 에서 읽고, TTY 없으면 비대화로 감지-only.
- **헤드리스/원격**: 브라우저 OAuth 는 localhost 콜백이 필요해 원격 불가 → device-code(`codex login --device-auth`) 또는 auth 복사.

## 4. 구현 범위

- **`runtime-wizard-catalog`**(#32852, #32857): CLI-transport 를 죽이지 않고 `subscription` 레코드로 emit(id·display_name·command·runtime_id). endpoint 필수 가정 제거. 로컬 서버는 이미 HTTP provider 라 별도 emit 불필요.
- **`masc runtime-probe <id>`**(#32897): subscription 로그인 판정을 셸에 복제하지 않고 서버와 **같은** `Runtime_claude_code.probe_subscription`/`Runtime_codex_app_server.probe_subscription`(모델 턴 없이 로그인만) 재사용. exit 0/1/2/3/4.
- **`masc mcp-config [--client env|codex|claude-desktop]`**(#32907): `Auth_login.mint`(서버 불필요) + typed `mcp_client` renderer 로 완성 config 블록 출력.
- **install.sh 마법사**: 로컬=endpoint 도달(curl `-fsS` healthcheck), subscription=`command -v`+`runtime-probe`, cloud=키 존재. 샌드박스 감지 리포트(#32884). auto-default(#32903, TTY 메뉴 default) + zero-config 비-TTY auto-select(#32914).

### 안 건드리는 것
- 하위 CLI 의 세션·토큰 갱신(그 CLI 소유). 토큰 추출/저장 안 함.
- 기존 `runtime.toml` 스키마(추가 emit 만; 수동 편집 경로 유지).
- 샌드박스 **선택**·백엔드 구현(RFC-0400/0405). 마법사는 **감지·안내만** 추가(§3.2) — 선택은 per-keeper.

> **원안 정정.** 초안 §4 는 "가용성 판정은 `keeper_capability_probe` 로" 라 적었으나, 실측 결과 `keeper_capability_probe` 는 **도구 descriptor 표면**을 보는 것이지 런타임 인증/도달을 보지 않는다. 실제 인증 probe 는 위 `runtime_claude_code`/`runtime_codex_app_server` 의 `probe_subscription` 이고, `runtime-probe` 가 이를 노출한다.

## 5. 안티패턴 (research 근거로 금지)

- **토큰 추출·복사 금지** — macOS Keychain 잠금 우회 취약점 보고. "로그인됨?" 만.
- **private auth 스키마 파싱 의존 금지** — auth.json/keychain 포맷은 준비공개·드리프트. probe 우선, 파일은 보조.
- **존재 ≠ 유효** — `expiresAt` 만료 가능. 갱신은 위임.
- **PATH/rc 자동편집은 옵트인** — 안내 우선.

## 6. 검증

- `install.sh --dry-run` 이 각 축의 감지 결과(녹색/안내)를 찍고, 아무것도 안 쓴다.
- `install-smoke.sh` 에 축별 감지 케이스(로그인 있음/없음, 로컬 endpoint 뜸/안뜸, docker 있음/없음) 추가.
- probe 레인으로 "선택된 런타임이 실제 도달 가능한가" 를 마법사 끝에서 1회 검증.

## 7. 미해결 항목 — 실측으로 답함

- **Codex/Claude 로그인 판정** → `probe_subscription`(=서버의 official-client probe)이 안정적인 검증이고, `runtime-probe` 가 이를 노출. 실측: `claude auth status --json` → `loggedIn/authMethod=claude.ai/apiProvider=firstParty`; 라이브 config 에서 `claude_code.claude-sonnet-5` authenticated(exit 0). 해결.
- **로컬 서버 포트·health 경로** → 마법사가 포트를 추측하지 않고 runtime.toml 의 provider-owned `healthcheck.path` 를 curl 한다(예: `/api/tags`, `/v1/models`, `/models`). 해결.

## 8. 남은 것 (별도 결정/RFC — 이번 범위 밖)

- **전역 기본 샌드박스 surface** — §3.2 대로 현재 자리가 없다. 마법사가 샌드박스를 *쓰게* 하려면 runtime.toml `[sandbox] default_profile` + loader + 소비자 신설이 필요(새 config Gate → 별도 RFC + 결정).
- **Antigravity 로그인 probe** — 서버의 official-client probe 도 antigravity 는 `login_probe_unsupported`(`server_dashboard_official_client_probe.ml`), `runtime-probe` 도 exit 3(unsupported). 관리형 oauth 파일 존재 검사는 §5 의 "존재 ≠ 유효" 안티패턴이라 채택 안 함. drift-safe 한 probe 가 생기기 전엔 막힘.
