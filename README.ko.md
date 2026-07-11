# MASC

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.4-orange.svg)](https://ocaml.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[English version](README.md)

> 정확한 설치 릴리스, 로컬 포트, provider 환경변수 같은 휘발성 값의 SSOT는
> [`README.md`](README.md), [`config/runtime.toml`](config/runtime.toml),
> [`docs/runtime-tunables.md`](docs/runtime-tunables.md)입니다. 이 한글 문서는
> 한국어 진입점이며, 그런 값은 의도적으로 복제하지 않습니다.

**MASC는 agent 작업을 위한 로컬 조율·관찰 레이어입니다.** 저장소 옆에서 MCP 서버로 돌면서 coding agent와 상주 Keeper가 goal, task, board 글, repository ownership, approval state를 같은 workspace에서 공유하게 합니다. 대시보드와 turn receipt로 agent의 결정과 실패를 들여다봅니다.

빠르게 일을 끝내는 도구라기보다, 속도 대신 조율·관찰성·장기 실행 persona 기반 agent 실험을 택한 도구입니다. 어떤 결정은 실용적이었고, 어떤 결정은 그냥 재미로 해본 실험입니다. 우연한 농담, 이상한 이름, 작은 설정놀음도 프로젝트 취향의 일부입니다. 그런 것들은 구조적 필연이라서가 아니라 재미있어서 남아 있습니다.

> **개발 상태:** MASC는 아직 pre-1.0 실험입니다. 생산성 도구, production service,
> 또는 security boundary가 아닙니다. 지금은 로컬 실험과 관찰 용도로만 사용하세요.
> CODE/IDE 흐름은 아직 실사용 가능한 상태가 아니며, HITL/Sandbox 기능도 사고를
> 일부 줄이는 운영 장치일 뿐 코드, secret, 인프라, 무인 agent 실행을 보호한다고
> 믿으면 안 됩니다. 현재 목표는 agent 실패를 충분히 보이게 만들어 어떤 workflow가
> 쓸모 있어질 수 있는지 찾는 것입니다.

**Keeper**는 MASC가 관리하는 선택적 상주 agent입니다. 서버가 살아 있는 동안 상주하며, heartbeat 주기로 스스로 turn을 돌거나 멘션·메시지를 받으면 반응합니다.

### 왜 Keeper인가 / Why "Keeper"

이 환경의 에이전트를 **Keeper**라고 부릅니다. 불프로그(피터 몰리뉴)의 게임 *던전 키퍼*에서 따온 애칭입니다. 프로젝트 안에서 쓰는 용어이자 장난스럽게 붙인 이름이지, 별도의 거창한 아키텍처 주장은 아닙니다. 우연한 농담과 캐릭터 같은 이름을 일부러 조금 남기는 프로젝트입니다.

---

## MASC로 할 수 있는 일 / What you can do

- **Goal·Task를 MCP 도구로 공유합니다.** 작업 소유권, 상태 전이, 검증 증거를 하나의 로컬 workspace에 둡니다.
- **상주 Keeper를 굴리고 관찰합니다.** Keeper마다 페르소나·목표·지시문을 주고, 같은 주제나 저장소 위에서 서로 소통하게 둡니다.
- **서로 다른 에이전트 스타일을 실험합니다.** Keeper마다 다른 관심사와 지시문을 줄 수 있고, 한 환경에서 무엇을 결정하고 어디서 부딪히는지 봅니다.
- **기성 코딩 에이전트를 붙입니다.** MASC는 MCP 서버라, Claude Code·Codex 같은 MCP 클라이언트를 `/mcp`에 연결하면 같은 워크스페이스에 참여합니다 — 태스크 claim·전이, 보드, goal을 공유하고 `masc_broadcast`·@mention으로 Keeper를 깨웁니다. (외부에서 Keeper turn을 동기로 직접 호출하는 도구는 없고, 워크스페이스와 멘션으로 상호작용합니다.)
- **같이 코드를 만질 때 뻔한 충돌을 줄입니다.** 여러 Keeper가 한 저장소를 고치면 turn·lock·작업자 소유권으로 조율을 시도하지만, concurrency safety를 보장하지는 않습니다.
- **결정과 실패를 들여다봅니다.** 웹 대시보드로 Keeper / Goal / Task / Board를 실시간으로 보고, turn마다 receipt가 남습니다.
- **위험한 동작은 사람 결정 대기열에 올립니다.** 자율 turn이 위험 도구를 호출하면 승인 대기로 멈춥니다 (HITL). 운영 장치이지 보안 보장은 아닙니다.
- **Keeper마다 모델을 다르게 설정합니다.** `runtime.toml` 한 줄로 runtime catalog에 있는 provider × model을 Keeper별로 지정합니다.

---

## 기능 / Features

상태 표기 — ✅ 지금 동작 · 🟡 부분 동작 · ❌ 미동작. 상태는 로컬 구현 경로 기준이며, production readiness나 security assurance가 아닙니다. 더 넓은 계획(cluster mode, 외부 IDE 확장, 추가 플랫폼 바이너리 등)은 [`ROADMAP.md`](ROADMAP.md)를 참고해 주세요.

| 기능 | 상태 | 한 줄 설명 | 사용자 진입점 |
|------|:----:|-----------|--------------|
| **Keepers** | ✅ | 페르소나·목표·지시문을 가진 상주 에이전트. 서버 기동 시 자동 부팅, 상태는 디스크에 영속 | `.masc/config/keepers/*.toml` |
| **HITL + Automatic** | 🟡 | 위험 도구 호출 승인 대기열. 우회 가능하며 security boundary가 아님. Critical은 현재 운영자 결정까지 대기 | 대시보드 승인 큐 |
| **Board** | ✅ | Keeper들이 글·댓글·투표로 비동기 협업, 게시가 관련 Keeper를 깨움 | `masc_board_*` 툴 / 대시보드 |
| **Sandbox (Docker)** | 🟡 | Docker profile 셸 실행은 fail-closed 컨테이너 경로이고, 명시적으로 선택한 `local` profile만 host 실행 | keeper TOML `sandbox_profile` + live `security_boundary` |
| **Dashboard** | ✅ | Keeper/Goal/Task/Board를 실시간으로 보고 명령을 내리는 웹 SPA | `dashboard/` (vite) |
| **TUI** | ❌ | Not working — `masc-tui` 실행 파일이 있으나, CJK/emoji 레이아웃·스트리밍 진행·rich-block 렌더링 등 주요 공백으로 실제로 사용할 수 없음 | `masc-tui` |
| **CODE / IDE (관망형)** | ❌ | Not working — LSP 프록시·주석 오버레이·대시보드 CODE 셸은 구현되어 있으나, 사람이 명령만 내리는 관망형 흐름이 검증되지 않아 실제로 사용할 수 없음 | 대시보드 Code |
| **OpenTelemetry** | 🟡 | OTLP HTTP exporter + GenAI semconv span/metric은 동작하나, 아직 수집되지 않는 signal과 instrumentation 공백이 많음 | `OTEL_EXPORTER_OTLP_ENDPOINT` |
| **Goal + Task** | 🟡 | Goal/Task CRUD·전이·검증·프롬프트 주입은 동작. 자동 스케줄링은 미구현 | `masc_goal_*` / `masc_*task*` 툴 |
| **Multi-Runtime** | 🟡 | Keeper별 provider×model 라우팅 | `runtime.toml` |
| **Provider Failover** | ❌ | provider 장애 시 자동 failover 없음; 수동 설정 변경 + 서버 재시작 필요 | `runtime.toml` |
| **Fusion (+ JoJ)** | 🟡 | 여러 모델에 같은 질문 후 심판 모델이 종합. Simple/Refine/Conditional 동작, JoJ 미배선 | `masc_fusion` 툴 |
| **Multi-Channel** | 🟡 | 외부 채널 메시지로 turn 시작/응답. 현재는 Discord만 라이브로 동작하고, Slack/Telegram은 사이드카 필요 | `POST /api/v1/gate/message` |

### 현재 동작과 한계

- **Keepers** — 각 Keeper는 서버가 살아 있는 동안 상주하는 장기 실행 에이전트입니다. heartbeat로 깨어나 turn을 돌고, 메모리·결정 로그는 디스크에 남아 재시작에도 복원됩니다. **한 Keeper는 한 번에 turn 하나만 돕니다**(동시에 두 일을 하지 않음) — 병렬은 여러 Keeper가 함께 도는 데서 옵니다. *한계*: `runtime.toml`의 `[autonomous] concurrency`는 코드가 읽지 않는 죽은 설정이고, fleet 크기는 `[bootstrap] autoboot_max` / `max_active_keepers`로 조절합니다.
- **HITL** — 프롬프트 지시가 아니라 도구 디스패치 경계에서 `Eio.Promise.await`로 강제됩니다. *한계*: `MASC_DISABLE_HITL=true`(기본 false)와 keeper `always_approve` 규칙으로 우회 가능합니다. 무응답 시 비Critical 도구는 approval silence timeout 뒤 거부되지만, **Critical 위험 도구는 현재 타임아웃이 없어 운영자가 결정할 때까지 turn이 정체될 수 있습니다.** HITL은 운영 workflow일 뿐이며 autonomous execution을 안전하게 만들어주지 않습니다.
- **Sandbox** — `docker run --rm`을 실제로 호출하고 cap-drop / no-new-privileges / read-only rootfs + 동시 실행 슬롯 제한을 적용합니다. 네트워크는 keeper의 `network_mode`로 제어합니다(`host`는 호스트 네트워크 namespace 공유, `none`은 loopback만 유지). Docker가 fail-safe 기본값이며 이미지/preflight 실패는 명시적 오류이고 host로 강등되지 않습니다. *한계*: 명시적으로 선택한 `local` profile은 host process입니다. BasePath 소유 managed HOME/XDG와 default-deny env를 쓰지만 filesystem namespace 격리는 없습니다.
- **Multi-Runtime** — `runtime.toml`의 `runtime.assignments`에 `keeper = provider.model` 한 줄이면 그 Keeper의 매 turn이 해당 provider로 갑니다.
- **Provider Failover** — provider 장애 시 순서 failover는 미구현입니다. 장애가 나면 default/assignment를 손으로 고치고 서버를 재시작해야 합니다.
- **Fusion + JoJ** — Keeper가 `masc_fusion`을 호출하면 패널 모델들이 같은 질문에 각자 답고 심판 모델이 합의/모순/맹점을 종합합니다. *한계*: JoJ(Judge of Judges) 위상은 코드·호출 경로가 있으나, 라이브 설정에 1차 심판 목록이 없어 호출 시 **fail-closed로 에러를 반환합니다**. 결과 registry는 in-memory라 재시작 시 사라집니다.
- **Goal + Task** — Goal/Task는 MCP 툴로 만들고 상태 전이하며, active goal은 Keeper system prompt에 주입됩니다. *한계*: goal-loop 스케줄러는 Keeper turn을 구동하지 않습니다(관측용). turn은 채널/이벤트로 구동됩니다.
- **OpenTelemetry** — OTLP HTTP exporter와 GenAI semconv span/metric이 동작합니다. *한계*: 아직 수집되지 않는 signal과 instrumentation 공백이 많습니다. 예를 들어 Keeper turn 낮은 수준 이벤트, fusion 나이부 metric, provider별 latency breakdown 등은 부분적으로만 커버됩니다.
- **CODE / IDE (관망형, 미동작)** — 사람이 코드를 직접 수정하지 않고 에이전트에게 명령만 내리는 관망형 IDE를 지향합니다. LSP 프록시·주석 오버레이·대시보드 CODE 셸은 구현되어 있으나, **관망형 명령 흐름이 검증되지 않아 현재 실사용 가능한 상태가 아닙니다.**

---

## 빠른 시작 (5분) / Quick Start

```bash
# 1. 바이너리 설치 (macOS arm64 / Linux x86_64)
brew install jeong-sik/masc/masc            # Homebrew (이 repo의 Formula/masc.rb)
#   또는:  curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash
#   소스 빌드: git clone https://github.com/jeong-sik/masc.git && cd masc &&
#     scripts/opam-pin-external-deps.sh --install && opam install . --deps-only &&
#     scripts/dune-local.sh build @default

# 2. 설정 시드 + provider 키 입력
masc init
#   .masc/config/.env.local 편집:
#     export OLLAMA_CLOUD_API_KEY=...     # 아래 표에서 하나 선택

# 3. 키 적용 + 시작
source .masc/config/.env.local && masc start
curl http://127.0.0.1:8935/health        # → 200 OK

# 4. (선택) 대시보드
cd dashboard && pnpm install && pnpm dev
```

Provider 키 (사용할 것을 `.masc/config/.env.local`에):

| `runtime.toml` provider | 환경 변수 |
|---|---|
| `ollama_cloud` | `OLLAMA_CLOUD_API_KEY` |
| `deepseek` | `DEEPSEEK_API_KEY` |
| `glm-coding` | `ZAI_API_KEY_SB` |
| `ollama` (로컬) | — (키 불필요) |

> `masc init`이 `.masc/config/runtime.toml`을 시드합니다(`[runtime].default` 포함). 서버가 `refusing to boot`를 로그하면 워크스페이스에서 먼저 `masc init`을 실행하세요. `masc start`는 subcommand 없이 `masc`를 실행한 것과 동일(가이드용 명시적 이름).

---

## 설치 / Install

### 바이너리 (prebuilt)

설치 스크립트를 먼저 확인하고 릴리스를 고정하는 경로를 권장합니다:

```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh -o /tmp/masc-install.sh
less /tmp/masc-install.sh
bash /tmp/masc-install.sh --version <release-tag>
```

버리는 로컬 환경에서는 편의상 아래 한 줄도 사용할 수 있습니다:

```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc/main/scripts/install.sh | bash
```

`$HOME/.local/bin/masc`에 바이너리를 설치하고 기본 설정(`tool_policy.toml`, `runtime.toml`)을 `<base-path>/.masc/config/`에 시드합니다. 제공 바이너리: **macOS arm64**, **Linux x86_64**. 그 외 플랫폼은 소스 빌드를 사용합니다.

설치 스크립트 요구 도구: `curl`과 기본 Unix 도구(`uname`, `chmod`, `mkdir`, `mktemp`)입니다. `jq`는 `--version` / `MASC_VERSION`을 생략해 GitHub latest release를 조회할 때만 필요합니다. Python/tomllib는 사용하지 않습니다. 재현 가능한 설치가 필요하면 `--version <release-tag>`로 고정하세요.

릴리스 바이너리는 GitHub releases에서 내려받습니다. 선택한 릴리스가 `SHA256SUMS`를 제공하면 설치 스크립트는 다운로드한 바이너리와 seed config(`tool_policy.toml`, `runtime.toml`)를 검증합니다. 기대 항목은 모두 존재해야 하며 값도 일치해야 합니다. 일부 기존 릴리스는 `SHA256SUMS`를 제공하지 않으며, 그런 릴리스는 검증된 바이너리 설치 경로를 사용할 수 없습니다. checksum 파일을 가져오지 못하면 기본값은 실패 종료입니다. 이 경우 아래 source build 경로를 쓰거나, 버리는 로컬 환경이나 air-gapped 설치에서만 `--allow-unverified` 또는 `MASC_ALLOW_UNVERIFIED=1`로 검증을 명시적으로 우회하세요. 이 경우 스크립트가 경고를 출력한 뒤 계속합니다.

> `runtime.toml`이 없거나 `[runtime].default`가 비어 있으면 서버는 `refusing to boot` 로그를 남기고 status 1로 종료합니다 — 환경 기본값 폴백은 없습니다. 기동에 필요한 파일이므로 설치 스크립트가 [`config/runtime.toml`](config/runtime.toml)을 시드합니다. 직접 작성하려면 `[runtime].default = "<provider>.<model>"`와 그에 대응하는 `[provider.model]` runtime binding table을 정의하세요. `[runtime.assignments]`는 선택 사항이며 Keeper별 override에만 씁니다.

### 소스 빌드 / From source

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
scripts/opam-pin-external-deps.sh --install   # 외부 OCaml 의존성 핀 및 설치
opam install . --deps-only
scripts/dune-local.sh build @default
```

요구 사항: OCaml ≥ 5.4, opam ≥ 2.0, dune ≥ 3.22. 빌드/테스트/CI 세부는 [`CONTRIBUTING.md`](CONTRIBUTING.md)를 참고해 주세요.

---

## 실행 / Run

MASC는 MCP 서버입니다. 기동한 뒤 에이전트/MCP 클라이언트를 그 서버에 붙입니다.

```bash
# 1. 서버 기동 (loopback)
PORT=8935   # 8935가 이미 사용 중이면 다른 로컬 포트 사용
masc --base-path "$PWD" --port "$PORT"     # 바이너리 설치 시
# 또는 소스에서:
./start-masc.sh --http --port "$PORT"

# 2. 상태 확인
curl "http://127.0.0.1:${PORT}/health"

# 3. MCP 클라이언트를 http://127.0.0.1:${PORT}/mcp 에 연결
```

| 실행 모드 | 명령 | 용도 |
|----------|------|------|
| 전체 런타임 | `./start-masc.sh --http --port <port>` | Keeper 스케줄러 포함 정식 기동 |
| 격리 기동 | `scripts/run-local.sh --target-dir /path` | 폴더별 격리, 로컬 포트 자동 할당 |
| Loopback | `scripts/start-loopback.sh` | 고정 loopback 포트, 스케줄러 끔(로컬 디버깅) |

대시보드는 별도로 띄웁니다:

```bash
cd dashboard && pnpm install && pnpm dev   # vite가 로컬 서버로 프록시
# 프로덕션 빌드: pnpm build
```

바이너리 설치 스크립트는 dashboard 소스를 clone하지 않습니다. 위 dashboard 명령은 repository checkout에서 실행하는 개발 경로입니다. 로컬 dashboard auth와 admin token 설정은 [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md)를 참고하세요.

---

## 설정 / Configuration

런타임 설정과 상태는 `--base-path` 아래 `.masc/`에 모입니다. 설정 파일은 `.masc/config/`에 있습니다.

**시작에 필요한 것**

| 파일 | 역할 |
|------|------|
| `runtime.toml` | provider/model 카탈로그 + `[runtime].default`. 기동에 필요: 파일(또는 `[runtime].default`)이 없으면 서버는 `refusing to boot` 로그를 남기고 status 1로 종료합니다 — 환경 기본값 폴백 없음 |
| `tool_policy.toml` | 설치 스크립트가 시드하는 config-root 마커(레거시). 현재 도구 접근은 레지스트리/디스크립터 기반이라 이 파일 내용은 런타임에 소비되지 않습니다 |

⚠️ **레거시 / 미사용 키**: `tool_policy.toml`은 config-root 마커일 뿐 내용은 런타임에서 읽지 않습니다. `runtime.toml`에 `[autonomous] concurrency`가 있다면 이 역시 죽은 설정입니다 — fleet 크기는 `[bootstrap] autoboot_max` / `max_active_keepers`로 조절합니다.

**에이전트를 만들 때**

| 파일 | 역할 |
|------|------|
| `prompts/keeper.world.md` | 모든 Keeper에 공통 주입되는 **World 프롬프트**(공통 무대·규칙, `<world>` 블록). 고치면 전체 무대가 바뀝니다 |
| `keepers/<name>.toml` | Keeper(등장인물) 정의 — goal·지시문·`persona_name`·`sandbox_profile`. World 위에 stack 됩니다 |
| `personas/<name>/profile.json` | (선택) 직접 작성하는 페르소나 JSON. `persona_name`으로 참조하며 여러 Keeper가 공유 가능합니다 |

**저장소에 코드 작업을 시킬 때만**

| 파일 | 역할 |
|------|------|
| `repositories.toml` | Keeper가 clone/작업할 저장소 등록. repo 작업이 없으면 불필요합니다 |
| `keeper_repo_mappings.toml` | Keeper → credential + 접근 가능 저장소 매핑 |
| `credentials.toml` | PR용 GitHub 자격증명 |

> `prompts/`의 나머지 `.md`는 행동·거버넌스·검증·메모리용 시스템 템플릿입니다. 이름으로 필요한 자리에서만 불려가고, 기본값으로 동작하므로 보통 건드리지 않습니다. "무대"를 바꾸려고 편집하는 것은 `keeper.world.md`입니다.
>
> 직접 작성하는 것은 `keepers/<name>.toml`(Keeper 정의)와 `personas/<name>/profile.json`(페르소나)입니다. 런타임 상태(`.masc/keepers/*.json` + `*.jsonl` 로그)는 서버가 생성하므로 손대지 않습니다.
>
> 실행 런타임 `.masc/`는 `--base-path`가 가리키는 곳입니다. 저장소 안의 `masc/.masc/`는 lock·scratch용입니다.

Keeper 정의 예시 (`keepers/<name>.toml`):

```toml
[keeper]
name = "albini"
persona_name = "albini"
goal = "흐름이 끊긴 task의 owner를 호명해 추궁합니다. 본인은 코드를 만들지 않습니다."
active_goal_ids = ["goal-pm-flow"]
sandbox_profile = "docker"     # 또는 "local"

instructions = """
... Keeper 행동 지시 ...
"""
```

Keeper → runtime 할당은 `runtime.toml`에서 합니다 (keeper toml은 model/runtime을 직접 갖지 않습니다):

```toml
[runtime.assignments]
albini = "<provider>.<model>"   # config/runtime.toml에 정의된 id로 교체
```

선택한 runtime이 cloud provider를 사용한다면 서버 시작 전에 필요한 provider credential을 export해야 합니다. runtime ID와 환경변수 knob의 SSOT는 [`config/runtime.toml`](config/runtime.toml)과 [`docs/runtime-tunables.md`](docs/runtime-tunables.md)입니다. provider key 이름을 README에 복제하지 않습니다.

---

## 디렉토리 구조 / Layout

```
masc/
├── bin/            서버·CLI 진입점 (main_eio = HTTP 서버, masc_tui = TUI, fusion_run …)
├── lib/            핵심 로직 (keeper/, board/, fusion/, gate/, ide/, server/, runtime/ …)
├── dashboard/      TypeScript + Preact 대시보드 SPA
├── docs/           스펙, 런북, RFC, 경계 문서
├── scripts/        설치·빌드·CI·운영 스크립트
├── config/         체크인된 기본 설정 (런타임이 시드로 사용)
├── test/           Alcotest 스위트
└── start-masc.sh   전체 런타임 기동 스크립트

<base-path>/.masc/ (런타임 상태, --base-path 아래)
├── config/         runtime.toml, keepers/, repositories.toml, credentials.toml …
├── keepers/        Keeper별 런타임 상태·메모리 (*.json + *.jsonl 로그, 서버 생성)
├── goals.json      Goal 상태
├── tasks/          Task 백로그, goal↔task 링크
├── board_*.jsonl   Board 글·댓글·투표 (append-only)
└── audit-approvals/  HITL 승인 이력
```

---

## 관련 프로젝트

이전 README에는 다른 agent runtime과의 상세 비교표가 있었습니다. 그 표는 당시 스냅샷으로는 유용했지만, 지금은 upstream의 실시간 inventory로 유지하지 않습니다. 현재 MASC의 로컬 계약은 위에서 설명한 범위로 읽으면 됩니다: repo-local MCP workspace, Keeper turn, dashboard/receipt 관찰성, `<base-path>/.masc/` 파일 상태, 그리고 `runtime.toml`을 통한 runtime assignment.

---

## Dashboard

대시보드는 해시 기반 라우터(`dashboard#<tab>?section=<section>`)로 서피스를 노출하는 웹 패널입니다. 서피스와 섹션의 canonical 정의는 `dashboard/src/config/navigation.ts`의 `DASHBOARD_SURFACES`와 `DASHBOARD_SECTION_ITEMS`이며, `hidden: true`로 표시된 항목(cockpit 등)은 UI에 노출되지 않습니다.

메인 네비게이션 레일에 고정되는 서피스(`V2_PRIMARY_SURFACE_IDS`):

| 서피스 | 설명 |
|---|---|
| Overview | 빠른 신호와 브리핑 요약 |
| Workspace | 작업 목표, 계획, 저장소, 검증 |
| Keepers | Keeper 로스터, 대화, 컨텍스트 워크스페이스 |
| Board | 사람·에이전트·자동화·시스템 게시물 |
| Schedule | 예약된 Keeper 자동화와 wake 신호 |
| Approvals | Keeper HITL 승인 큐 (도구 호출 게이트) |
| Fusion | masc_fusion 패널·심판 숙의 |
| Code | 실험적 CODE/IDE 셸; 실제 코딩 workflow에는 아직 사용할 수 없음 |
| Connectors | 채널 사이드카와 Keeper 바인딩 |
| Settings | Keeper 설정 운영 콘솔 |
| Logs | 시스템 실행 로그 |

레일 외부에서 접근 가능한 추가 서피스: Monitor (keeper fleet, 도구 모니터, 런타임, observatory), Command (개입·거버넌스·승인), Lab (도구 진단, safety harness, 성능, Memory OS, 키퍼 메모리 상태).

라우트 예시: `dashboard#monitoring?section=agents`, `dashboard#monitoring?section=journey`, `dashboard#command?section=operations`, `dashboard#connectors?section=connector-status`, `dashboard#lab?section=memory-subsystems`, `dashboard#workspace?section=verification`.

(`monitoring?section=journey` 같은 일부 진단 뷰는 `navigation.ts` 레일 서피스가 아니라 `dashboard/src/components/status.ts`의 라우트-전용 매핑으로 제공됩니다 — 레일 라벨 없이 라우트로만 도달합니다.)

---

## 문서 / Documentation

이 저장소의 문서는 모두 같은 신뢰도를 갖지 않습니다. `status`와 `last_verified`를 명시한 파일을 우선하고, 오래된 design/RFC 문서는 현재 runbook에서 다시 링크하지 않는 한 역사/맥락 문서로 읽어야 합니다.

| 문서 | 용도 | 현재성 메모 |
|---|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 빌드/테스트/PR 기대치 | contributor workflow 문서이며 제품 홍보 문서가 아님 |
| [`ROADMAP.md`](ROADMAP.md) | 6-8주 운영 관점 | 버전 헤더는 `dune-project`와 `CHANGELOG.md`에 맞는지 확인 |
| [`docs/OAS-MASC-BOUNDARY.md`](docs/OAS-MASC-BOUNDARY.md) | MASC ↔ OAS 경계 | reference 문서; 오래된 본문보다 `last_verified`와 generated pin block 우선 |
| [`docs/spec/SPEC-INDEX.md`](docs/spec/SPEC-INDEX.md) | spec suite 진입점 | living draft; 개별 spec에는 migration context가 남아 있을 수 있음 |
| [`docs/KEEPER-USER-MANUAL.md`](docs/KEEPER-USER-MANUAL.md) | Keeper 개념과 운영 메모 | 오래된 manual; config truth는 [`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md), [`config/runtime.toml`](config/runtime.toml), live code 우선 |
| [`docs/keeper-turn-lifecycle.md`](docs/keeper-turn-lifecycle.md) | historical lifecycle notes | [`docs/spec/04-turn-lifecycle.md`](docs/spec/04-turn-lifecycle.md)가 권위 문서 |
| [`docs/RELEASE-EVIDENCE.md`](docs/RELEASE-EVIDENCE.md) | release evidence bundle | 형식 문서; 사용 전 version line을 current release metadata와 맞출 것 |

대시보드 라우트 포맷·서피스 목록은 위 [Dashboard](#dashboard) 섹션을 참고해 주세요.

---

## 남은 과제 / Roadmap

아래는 현재 한계를 바탕으로 정리한 구체적인 남은 작업입니다. 더 넓은 운영 계획은 [`ROADMAP.md`](ROADMAP.md)를 참고해 주세요.

| # | 영역 | 남은 작업 | 상태 변화 예상 |
|---|------|----------|---------------|
| 1 | **Keepers / Fleet** | `runtime.toml`의 `[autonomous] concurrency`를 삭제하거나, 실제 fleet 동시성 제어(`[bootstrap] autoboot_max`, `max_active_keepers`)로 대체해 문서와 코드를 맞춥니다. | 🟡→✅ |
| 2 | **Provider Failover** | provider healthcheck 기반 **자동 순서 failover**를 구현합니다. 장애 시 다음 후보 provider로 Keeper turn을 자동 전환하고, 복구 시 로그/메트릭을 남깁니다. | ❌→✅ |
| 3 | **Fusion + JoJ** | `runtime.toml`에 JoJ(Judge of Judges)용 1차 심판 패널(`judges`) 설정을 추가하고, fusion 결과 registry를 디스크에 영속화합니다. | 🟡→✅ |
| 4 | **Goal + Task** | goal-loop 스케줄러가 채널 이벤트 외에도 Keeper turn을 구동할 수 있도록 합니다. 예: goal 상태 변화·마감 임박·blocked 태스크 발견 시 자동 wake. | 🟡→✅ |
| 5 | **TUI** | `masc-tui`를 실제로 사용 가능한 상태로 만듭니다. 실행 파일은 있으나 CJK/emoji 레이아웃·스트리밍 진행·rich-block 렌더링 공백으로 현재는 사용할 수 없습니다. | ❌→🟡/✅ |
| 6 | **IDE** | 관망형 IDE를 실제로 사용 가능한 상태로 만듭니다. LSP 프록시·주석 오버레이·대시보드 IDE 셸은 있으나, 사람이 명령만 내리는 흐름이 검증되지 않아 현재는 사용할 수 없습니다. | ❌→🟡/✅ |
| 7 | **Multi-Channel** | Slack·Telegram 등 Discord 외 채널용 **사이드카**를 추가하고, gate message 스키마를 채널별로 확장합니다. | 🟡→✅ |
| 8 | **Sandbox** | Docker 이미지/preflight 실패는 fail-closed 처리하고, `sandbox_profile=local`은 비격리임이 명시된 operator 선택으로만 둡니다. | ✅ 안정화 |
| 9 | **HITL** | Critical 위험 도구의 **타임아웃/에스컬레이션 정책**을 정의합니다. 영구 정체를 방지하면서도 중요한 결정은 사람이 내릴 수 있도록 합니다. | ✅ 안정화 |
| 10 | **Governance** | `MASC_DISABLE_HITL=true`와 keeper `always_approve` 규칙의 사용 범위를 제한하고, 운영자 감사 로그를 강화합니다. | ✅ 안정화 |
| 11 | **OpenTelemetry** | Keeper turn 낮은 수준 이벤트, fusion 나이부 metric, provider별 latency breakdown 등 누락된 signal과 instrumentation을 추가합니다. | 🟡→✅ |

---

## 상태 / Status

pre-1.0 (`0.y.z`). API와 설정 형식은 바뀔 수 있습니다. `1.0.0`은 저장소 협업·릴리스·운영자 경로가 caveat 없이 신뢰될 때까지 열지 않습니다.

## License

MIT. 보증 없이 "있는 그대로" 제공됩니다. 자세한 내용은 [`LICENSE`](LICENSE)를 참고해 주세요.
