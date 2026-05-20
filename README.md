# masc-mcp

[![OCaml](https://img.shields.io/badge/OCaml-5.4+-orange.svg)](https://ocaml.org/)
[![OAS](https://img.shields.io/badge/agent__sdk-%E2%89%A50.193.9-blue.svg)](https://github.com/jeong-sik/oas)

> **개인 프로젝트입니다. 저자(jeong-sik / yousleepwhen) 한 사람이 자기 노트북에서 자기 워크플로우를 위해 만든 도구입니다.** 프로덕션 SLA, 외부 지원, 호환성 보증, 응답 시간 약속이 *전혀* 없습니다. 외부에서 production 으로 쓰지 마세요. 스키마, 도구 surface, 대시보드, CLI flag 는 매우 빠르게 바뀝니다 — 이 README 가 본 1000 PR 윈도우 (#14012 → #15155) 는 2026-05-07 부터 2026-05-14 까지 7일 만에 머지된 분량입니다.
>
> Personal project. One author, one laptop, one workflow. No SLA, no support, no compatibility guarantees. The 1000-PR window cited below (#14012 → #15155) merged in 7 days (2026-05-07 → 2026-05-14).

OCaml 5.4 + Eio 위에서 도는 MCP 서버. 같은 저장소를 동시에 만지는 코딩 에이전트들(Claude, Codex, Gemini, 로컬 모델)이 turn / lock / heartbeat / 작업 owner 를 공유하기 위한 상태 저장소입니다. 단일 머신 / 신뢰 네트워크 / 저자 한 사람이 운영하는 환경을 가정합니다.

이 문서는 위 7일 윈도우 동안 실제로 손댄 영역만 적습니다.

## 무엇을 위해 만들었나

저자가 *직접* 사용하는 시나리오 한 가지:

- 여러 코딩 에이전트가 같은 저장소에서 **동시에 PR 을 열고 닫는다**.
- 같은 파일을 동시에 만지면 충돌하므로, 누가 어떤 task 를 claim 했는지, 어떤 worktree 를 잡았는지, 마지막 heartbeat 가 언제였는지를 *한 곳에서* 본다.
- 에이전트가 죽거나 컨텍스트를 잃으면 supervisor 가 보고 개입한다.

이 시나리오에 들어가지 않는 모든 use case 는 미지원입니다.

## 무엇이 아닌가

다음은 *명시적으로* 지원하지 않습니다.

- multi-tenant SaaS 격리
- hostile network 또는 인터넷 노출
- 무인 production 운영
- 모델 서빙 플랫폼
- 일반 workflow scheduler
- LTS / semver 호환 약속

## Architecture

```
┌──────────────────────────────────────────────────┐
│              Consumer / Client                    │
│       (Claude, Gemini, Codex, Local Agent)        │
└────────────────┬─────────────────────────────────┘
                 │  MCP (JSON-RPC over HTTP/SSE)
┌────────────────▼─────────────────────────────────┐
│            MASC-MCP  (coordination)               │
│                                                   │
│  Room/Board  Keeper   Cascade     Operator        │
│  Tasks       Goal     Governance  Dashboard / IDE │
│                                                   │
│         ┌── OAS bridges ──┐                       │
└─────────┤                 ├───────────────────────┘
          │                 │
┌─────────▼─────────────────▼──────────────────────┐
│         OAS / agent_sdk  (agent runtime)          │
│  Agent.run  Builder  Hooks  Checkpoint  Memory    │
└──────────────────────────────────────────────────┘
```

**경계 (RFC-0058 / OAS-MASC-BOUNDARY 가 SSOT):** MASC 가 *언제 / 왜 / 어떤 provider chain 을* 부를지 결정합니다. OAS 는 그렇게 선택된 단일 provider 호출의 실행 (tool dispatch, context, retry) 만 책임집니다. MASC → OAS 의존, 역방향 의존은 없습니다.

### Transport

| Protocol | Default port | 비고 |
|----------|--------------|------|
| HTTP/1.1 + HTTP/2 | `8935` | 1차 MCP endpoint `/mcp` |
| SSE | `8935` | h2 connection 당 무제한 stream |
| gRPC | `8936` | keeper 조회 / 구독 |
| WebSocket | `8937` | `/ws` discovery (experimental) |
| WebRTC | `8935` | `POST /webrtc/offer`, `/answer` (experimental, gated) |

모두 같은 Eio fiber pool 에서 돕니다 (Lwt 없음).

## 코드 구조

`lib/` 는 평면 namespace 가 아니라 sub-library 들로 분리되어 있습니다. 새로 읽기 시작한다면 다음 순서를 권합니다.

| Sub-lib | 들어 있는 것 |
|---------|-------------|
| `lib/keeper/` | 12-state FSM, supervisor, heartbeat, checkpoint, compaction |
| `lib/cascade/` + `lib/cascade_decl/` | 모델 선택 정책, TOML 스키마, validation (RFC-0058) |
| `lib/cdal/` + `lib/cdal_runtime/` | CDAL (coordination / decision audit layer) 평가 / 판정 |
| `lib/coord/` | room, board, task, claim 같은 coordination primitive |
| `lib/operator/` | supervisor / operator 측 admin surface |
| `lib/dashboard/` + `dashboard/` (TS) | 읽기 위주 UI |
| `lib/ide/` | 다음 §IDE Surface 참고 |
| `lib/exec/` + `lib/gate/` | 외부 명령 / 컨테이너 실행 게이트 (RFC-0070) |
| `lib/tool_schemas/` + `lib/tool_schemas_specs/` | MCP 도구 schema codegen (RFC-0057) |
| `lib/repo_manager/` | worktree / branch 라이프사이클 |
| `lib/server/` | HTTP/SSE/gRPC/WS/WebRTC transport |
| `lib/goal/`, `lib/memory/`, `lib/autoresearch/` | goal 추적 / 메모리 / 연구 보드 |

`bin/` 의 최상위 실행 파일: `main_eio.exe` (HTTP/SSE 서버), `main_stdio_eio.exe` (stdio MCP), `masc_tui.exe` (TUI), `masc_compaction_audit.exe`, `masc_trace.exe`, 그리고 `gen_tool_descriptors.exe` (RFC-0057 codegen entry).

## Quick Start

### 사전 빌드 바이너리 설치 (macOS arm64 / Linux x86_64)

```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc-mcp/main/scripts/install.sh | bash
```

`scripts/install.sh` 가 하는 일:

- 최신 GitHub Release 바이너리를 `~/.local/bin/masc-mcp` 로 다운로드
- boot 에 필요한 최소 config (`./.masc/config/tool_policy.toml`) 시드
- `--version` smoke check

flag 예시 (`install.sh --help` 가 전체 목록):

```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc-mcp/main/scripts/install.sh \
  | bash -s -- --version v0.8.0 --prefix /usr/local/bin --base-path /path/to/project
```

`--dry-run` 으로 쓰기 없이 확인 가능.

### 소스 빌드

위 두 플랫폼 외이거나, 미발행 commit 이 필요하거나, 코드를 만질 때:

```bash
git clone https://github.com/jeong-sik/masc-mcp.git
cd masc-mcp

scripts/opam-pin-external-deps.sh        # OAS, mcp_protocol 등 비공개 의존성 pin
opam install . --deps-only
scripts/dune-local.sh build bin/main_eio.exe

scripts/run-local.sh --target-dir "$PWD"
PORT="$(scripts/run-local.sh --print-port --target-dir "$PWD")"
curl "http://127.0.0.1:${PORT}/health"
./_build/default/bin/main_eio.exe doctor --base-path "$PWD"
```

`scripts/dune-local.sh` 는 worktree 동시 빌드 직렬화를 위한 글로벌 lock 을 씁니다 (`/tmp/me-dune-local.lock`). 여러 worktree 에서 `dune build` 를 동시에 돌리면 대기열을 탑니다.

### 기동 모드

| 모드 | 명령 | 용도 |
|------|------|------|
| Loopback | `scripts/start-loopback.sh` | 로컬 개발, 고정 포트 8935, keeper off |
| Dir-local | `scripts/run-local.sh --target-dir /path` | 프로젝트별 격리, 경로에서 결정론적 포트 선정 (9100-9999) |
| Full runtime | `./start-masc-mcp.sh --http` | 모든 transport, keeper autoboot, dashboard |
| Stdio MCP | `./start-masc-mcp.sh --stdio` | stdio-only 클라이언트 |
| Direct binary | `./_build/default/bin/main_eio.exe --port 8935 --base-path /path/to/base` | 수동; runtime root는 `/path/to/base/.masc` |

기본값:

- bind host: `127.0.0.1`
- runtime data root: `<base-path>/.masc`
- dir-local data root: `<target>/.masc/`
- dir-local config root: `<target>/.masc/config`
- dir-local transports: HTTP on, gRPC/WS/WebRTC off
- dir-local bootstrap: 체크인된 `config/keepers/*.toml` 시드 *제외* (필요 시 `--bootstrap-keepers` 명시)

`0.0.0.0` 이나 `::` 로 bind 하면 strict auth 가 강제됩니다. 자세한 건 [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md), [docs/spec/09-server-transport.md](docs/spec/09-server-transport.md).

## MCP Client Setup

```json
{
  "mcpServers": {
    "masc": {
      "type": "http",
      "url": "http://127.0.0.1:8935/mcp"
    }
  }
}
```

- `/mcp` — full 표면 (local-first)
- `/mcp/operator` — bearer-token, 원격 안전한 축소 표면
- 템플릿 모음: [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md)
- dir-local 포트로 바꿔야 한다면: `scripts/run-local.sh --print-port --target-dir ...`

## Keeper System

Keeper 는 장기 실행 자율 에이전트 fiber 입니다. heartbeat / checkpoint / 감독 재시작이 붙어 있고, OAS 의 `Agent.run` 호출을 turn budget 안에서 호출합니다.

### 12-state Lifecycle

진실의 출처는 `lib/keeper/keeper_state_machine.mli` 의 `type state` 입니다. README 가 어긋나면 `.mli` 를 따르세요.

```
Offline       등록됨, heartbeat fiber 아직 없음
Running       정상 heartbeat
Failing       연속 실패, 복구 probe
Overflowed    provider context 초과, auto-compact 진입
Compacting    context compaction 진행 중
HandingOff    세대 rollover 진행 중
Draining      현재 turn 마치고 정리 중
Paused        operator-paused 또는 compact-retry exhausted
Stopped       정상 종료 (terminal)
Crashed       복구 불가 오류, 재시작 후보
Restarting    supervisor backoff
Dead          restart budget 소진 (terminal)
```

대략적인 흐름: `Offline → Running → {Failing | Overflowed | Compacting | HandingOff | Draining} → Paused / Stopped / Crashed → Restarting → Dead`.

### Autoboot

`config/keepers/*.toml` 정의를 부팅 때 발견하고 staggered warmup 으로 띄웁니다 (`MASC_KEEPER_BOOTSTRAP_ENABLED=true` 일 때만).

### Turn Budget

각 `Agent.run` 호출은 `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` (기본 15) turn 으로 제한됩니다. 소진되면 checkpoint 저장 후 다음 heartbeat 에서 재개. 개별 keeper 가 `extend_turns` 로 절대 ceiling 200 까지 요청 가능합니다.

Adaptive OAS timeout: `base 180s + 1.5s × (context tokens / 1K)`, `[30, 600]s` clamp.

### 주요 환경변수

| 변수 | Default | 설명 |
|------|---------|------|
| `MASC_KEEPER_BOOTSTRAP_ENABLED` | `true` | autoboot on/off |
| `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC` | `30` | heartbeat 주기 (5-300) |
| `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` | `15` | turn / call (1-50) |
| `MASC_KEEPER_OAS_TIMEOUT_SEC` | adaptive | OAS timeout 강제 override (30-600) |
| `MASC_KEEPER_TURN_TIMEOUT_SEC` | `1200` | wall-clock turn guard (60-3600) |
| `MASC_KEEPER_SUPERVISOR_MAX_RESTARTS` | `5` | Dead 전까지 재시작 |
| `MASC_KEEPER_IDLE_SKIP_THRESHOLD` | `4` | 연속 idle 후 Skip |

전체: `lib/config/env_config_keeper.ml`. Per-keeper: `config/keepers/*.toml`.

운영 메모:

- `repo/config` 는 체크인 시드일 뿐 *live* 가 아닙니다. live 는 `MASC_CONFIG_DIR` 또는 `<base-path>/.masc/config`.
- 설정에 의심이 들면 `main_eio.exe doctor --base-path "$PWD"` 부터.

Reload 계약 ([docs/TOML-RELOAD-MATRIX.md](docs/TOML-RELOAD-MATRIX.md)):

- env vars → boot 시점 고정 (런타임 control plane 이 명시적으로 reload 하지 않는 한)
- `config/keepers/*.toml` → 다음 supervisor sweep 에서 reconcile
- `config/cascade.toml` → 다음 model resolve / turn 에서 in-memory render
- `config/keeper_runtime.toml`, `config/tool_policy.toml` → restart 필요

## Model Cascade

- 작성 매뉴얼: [docs/CASCADE-TOML.md](docs/CASCADE-TOML.md)
- live SSOT: `config/cascade.toml` (`config/cascade.json` 은 retired, 더 이상 생성/소비되지 않음)
- 스키마 / parsing / 선택 정책 은 MASC 소유. OAS 에는 *해결된 단일 provider/model* 만 넘어갑니다.
- keeper TOML 안의 `cascade_name` 으로 per-keeper override 가능.
- 시드에서 keeper 가 정상 선택할 수 있는 프로필은 `primary` 뿐. `default`, `local_only`, `local_recovery`, `scoring` 은 시스템 전용 plumbing.
- 체크인 cascade 의 provider 는 현재 pin 된 OAS 런타임이 *실제로* 실행할 수 있는 provider 로만 채워야 합니다.
- 복붙용 로컬/개인 예시: [docs/CASCADE-COOKBOOK.md](docs/CASCADE-COOKBOOK.md)
- 경계 문서: [docs/OAS-MASC-BOUNDARY.md](docs/OAS-MASC-BOUNDARY.md), [docs/spec/13-oas-integration.md](docs/spec/13-oas-integration.md), [docs/spec/14-configuration.md](docs/spec/14-configuration.md)

## Safe Starting Paths

### 1. 코딩 워크플로우 coordination

```text
masc_start(path="/your/project", task_title="My first task")
```

표준 호출 순서:

- `masc_start`
- `masc_status`
- `masc_transition(action="claim")` 또는 `masc_claim_next`
- `masc_plan_set_task` (필요 시)
- `masc_heartbeat`

### 2. Supervisor / Operator 분리

planner / implementer / supervisor 를 다른 도구로 분리할 때:

- 런타임 측: 일반 board + task hygiene
- supervisor 측: `/mcp/operator` 의 `masc_operator_snapshot`, `_digest`, `_action`, `_confirm`
- 런북: [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md)

### 3. 대시보드 surface

읽기 위주 UI. 쓰기 정식 경로는 MCP 도구.

- Monitoring: `http://127.0.0.1:<PORT>/dashboard#monitoring?section=journey`
- Fleet Health: `dashboard#monitoring?section=fleet-health`
- Ops: `dashboard#command?section=operations`
- Connectors: `dashboard#connectors?section=connector-status`
- Workspace: `dashboard#workspace?section=verification`
- Lab: `dashboard#lab?section=tools`

대시보드 빌드:

- `scripts/run-local.sh` 는 dashboard 를 자동 빌드하지 않습니다. 필요할 때 `--build-dashboard`.
- `start-masc-mcp.sh --http` 는 `scripts/build-dashboard-if-needed.sh` 를 백그라운드로 띄웁니다. 차단 빌드가 필요하면 `MASC_DASHBOARD_BUILD_BLOCKING=1`.
- 대시보드 dev server 직접 띄우기:

  ```bash
  PORT="$(scripts/run-local.sh --print-port --target-dir "$PWD")"
  cd dashboard && MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:${PORT}" pnpm run dev
  ```

- 수동 rebuild: `cd dashboard && pnpm run build`
- `Forbidden` / `cannot CanAdmin` 이 나오면 `./_build/default/bin/main_eio.exe doctor auth --base-path "$PWD"` 먼저.

External 채널 어댑터의 경계는 Channel Gate:

- write/traffic: `/api/v1/gate/message`
- read/descriptor: `/api/v1/gate/connectors`
- per-channel metrics: `/api/v1/gate/status`
- Discord 봇 셋업: [sidecars/discord-bot/README.md](sidecars/discord-bot/README.md)

## IDE Surface

지난 1000 PR 의 48 건이 `feat(ide)` / `fix(ide)` 였습니다. `lib/ide/` 가 `masc_mcp.ide` sub-library 로 분리되어 있고, dashboard 쪽 IDE 패널과 backend 가 다음을 공유합니다.

- 파일 트리 / breadcrumb 에 어떤 keeper 가 어떤 파일을 보고 있는지 (file focus)
- CodeMirror 6 기반 multi-keeper cursor overlay
- LSP `textDocument/hover`
- BDI inspector — keeper 의 belief / desire / intention 단계 노출
- 메모리 tier 패널 (working / episodic / semantic 구분)
- presence strip 에서 keeper 의 PR 상태, click-to-navigate
- context lens — keeper tool call 이 만진 코드 위치로 routing back
- audit log / telemetry / planning / board / git graph route 가 같은 focus context 로 묶임

핵심 모듈: `lib/ide/ide_region_tracker.ml`, `ide_annotations.ml`, `ide_annotation_types.ml`, `ide_paths.ml`. backend 쪽 region write 진입점은 `lib/keeper/keeper_exec_fs.ml` 의 write 흐름이 `Ide_region_tracker.ingest_tool_call` 로 전달되는 지점.

상태: 활발히 churn 중. RFC-0071 §3.4 의 fragile-match warning 4 가 이 sub-lib 에 켜져 있어서 (`dune` 의 `-w +4`) 새 코드는 exhaustive match 을 강제합니다.

## 활성 RFC 트랙 (위 7일 윈도우)

내가 PR 제목에서 직접 인용을 확인한 항목만 적습니다. 진행도는 PR open/closed 와 머지 시점 기준.

| RFC | 주제 | 머지된 PR 수 (1000 윈도우 / 7일) |
|-----|------|------------------------------|
| RFC-0058 | Cascade decl SSOT — closed-variant dispatch 제거, capability 기반 분기, TOML schema 확장 | 50 |
| RFC-0070 | Sandbox / Docker 실행 게이트 — `Docker_client.S` typed, `Sandbox_executor` functor, exec / ps / run 분리 | 24 |
| RFC-0071 | OCaml warning 4 (fragile match) 켜기 + sub-lib 별 fragile site 닫기 | 22 |
| RFC-0057 | MCP tool descriptor codegen — `bin/gen_tool_descriptors.exe` 가 스키마 생성 | 15 |
| RFC-0062 | 문서 / 스펙 백필 | 10 |
| RFC-0072 | Keeper sub-FSM 전이를 GADT + typed resolver 로 (decision / cascade / turn_phase / compaction 4축) | 7 |
| RFC-0005 | 장기 트랙 문서 갱신 | 14 |
| RFC-0041 | 스펙 정렬 | 11 |
| RFC-0047 | 스펙 정렬 | 11 |

병행해서 굵직하게 본 흐름:

- **Telemetry typed labels** (~22 PR): Prometheus metric label 의 free-form string 을 `*_failure_site` / `*_kind` / `*_operation` 같은 closed sum 으로 교체. cardinality 닫고, 새 label 누락을 컴파일 타임에 잡기 위함.
- **TLA+ spec maintenance** (~31 PR `docs(tla-audit)`): keeper / cascade / decision FSM 의 TLA spec 을 main 코드와 일치시키는 audit + buggy-cfg 검증. `KeeperOASAdvanced.tla` 같은 mutation-testing 스타일 spec 이 들어 있음.
- **Sub-lib extraction** (`refactor(keeper)` 35 PR + `refactor(dashboard)` 17 PR): `lib/` 평면을 sub-library 로 쪼개는 작업이 RFC-0056 이후 지속.

각 RFC 문서는 `docs/rfc/RFC-NNNN-*.md` 에 있습니다. 번호 충돌이 과거에 한 번 일어났으므로 (2026-05-09 RFC-0057 충돌), 새 RFC 작성 전 `ls docs/rfc/` 확인 권장.

## Verification

```bash
make test           # 유닛 테스트 (서버 불필요)
make ci             # 전체 CI suite
```

서버를 띄운 뒤 smoke:

```bash
curl -sS http://127.0.0.1:8935/health
grpcurl -plaintext 127.0.0.1:8936 grpc.health.v1.Health/Check
scripts/verify-dashboard.sh http://127.0.0.1:8935
make release-evidence
```

CI 와 동일한 heartbeat 로그 / timeout 으로 로컬 재현:

```bash
CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
  scripts/ci-run-tests.sh "scripts/dune-local.sh test"
```

raw `opam exec -- dune ...` 은 의도적인 CI-parity 점검 때만. 평소 개발은 focused target + 위 wrapper 사용.

## Transport and Auth

- `POST /mcp` 는 `Accept: application/json, text/event-stream` 필요.
- legacy `/sse`, `/messages` 는 deprecated.
- `0.0.0.0` / `::` bind 시 strict auth 강제, 로컬 `/mcp` 도 `require_token=true` 가 아니면 fail-closed.
- `/mcp/operator` 는 bearer-token + 원격 안전한 축소 surface. full `/mcp` 를 외부에 노출하지 않습니다.
- command-plane 호환 lane 은 retired. 새 caller 가 의존하지 말 것.
- role / bearer mismatch (예: `codex cannot CanAdmin`) 진단은 `doctor auth` 부터.
- 상세: [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md), [docs/spec/09-server-transport.md](docs/spec/09-server-transport.md)

## Document Map

자주 들어가는 문서만. 전체 spec 인덱스는 `docs/spec/SPEC-INDEX.md`.

| 문서 | 내용 |
|------|------|
| [docs/QUICK-START.md](docs/QUICK-START.md) | 설치, health, 첫 워크플로 |
| [docs/CONFIG-DOCTOR.md](docs/CONFIG-DOCTOR.md) | 활성 config / init 진단, root 선정 |
| [docs/BOOT-ENV-STATE-INVENTORY.md](docs/BOOT-ENV-STATE-INVENTORY.md) | boot / path / state 인벤토리 |
| [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md) | HTTP / stdio MCP 클라이언트 템플릿 |
| [docs/CASCADE-TOML.md](docs/CASCADE-TOML.md) | cascade.toml 작성 매뉴얼 |
| [docs/CASCADE-COOKBOOK.md](docs/CASCADE-COOKBOOK.md) | 복붙용 로컬 / 개인 예시 |
| [docs/OAS-MASC-BOUNDARY.md](docs/OAS-MASC-BOUNDARY.md) | OAS / MASC 소유 경계 |
| [docs/KEEPER-USER-MANUAL.md](docs/KEEPER-USER-MANUAL.md) | keeper 라이프사이클, sandbox profile, Docker one-shot/managed 실행, 트러블슈팅 |
| [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md) | supervisor / operator 워크플로 |
| [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | dashboard auth, `doctor auth` |
| [docs/ENV-CONTRACT.md](docs/ENV-CONTRACT.md) | 환경변수 boot 계약 |
| [docs/TOML-RELOAD-MATRIX.md](docs/TOML-RELOAD-MATRIX.md) | toml 별 reload 시점 |
| [docs/RELEASE-EVIDENCE.md](docs/RELEASE-EVIDENCE.md) | 릴리즈 smoke + proof bundle |
| [docs/BENCHMARK-RUNBOOK.md](docs/BENCHMARK-RUNBOOK.md) | 벤치마크 / 비교 하네스 |
| [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) | 6-8 주 운영 트랙 (개인 운영 기준) |
| [docs/PRODUCT-REVIEW.md](docs/PRODUCT-REVIEW.md) | promise 단계별 현재 자세 |
| [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md) | spec suite |
| [ROADMAP.md](ROADMAP.md) | 버전 / 릴리즈 / 활성 트랙 |
| [CHANGELOG.md](CHANGELOG.md) | 버전별 변경 로그 (현재 v0.19.26) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 기여 — 사실상 저자 self-discipline 문서 |
| [llms.txt](llms.txt) / [llms-full.txt](llms-full.txt) | 언어모델용 압축 front door |

## License

MIT. 라이선스가 보증을 의미하지는 않습니다. 윗문단을 다시 읽어주세요.
# Canary test for draft-PR upload readiness
