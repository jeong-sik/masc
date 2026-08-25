# MASC

[![OCaml](https://img.shields.io/badge/OCaml-5.5-orange.svg)](https://ocaml.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[English](README.md)

MASC(Multi-Agent Shared Context)는 같은 프로젝트에서 일하는 여러
에이전트가 작업 상태를 공유하도록 돕는 로컬 MCP 서버입니다. 목표, 작업,
담당자, 보드 글, 실행 근거를 한 작업 공간에 저장하고 MCP와 웹 대시보드로
보여줍니다.

**Keeper**는 MASC가 관리하는 선택형 상주 에이전트입니다. 공유 작업 공간에서
이벤트를 받아 장기 작업을 수행합니다. MASC를 협업용 MCP 서버로만 쓸 때는
Keeper가 없어도 됩니다.

> **개발 상태:** MASC는 로컬의 신뢰할 수 있는 환경을 대상으로 하는 pre-1.0
> 프로젝트입니다. 운영 서비스나 보안 경계로 사용할 수 없습니다. Gate, 사람
> 승인(HITL), Docker 실행은 일부 작업을 제한하지만, 무인 에이전트의 모든 위험한
> 행동을 막아주지는 않습니다. IDE와 TUI는 실험 단계입니다. `main`의 코드는
> 최신 공개 바이너리보다 앞서 있을 수 있습니다.

![MASC 대시보드 개요](docs/screenshots/dashboard/2026-08-21/01-overview.png)

로컬에서 실행 중인 MASC를 캡처한 화면입니다. 운영 정보는 알아볼 수 없도록
바꿨습니다. [대시보드 화면 목록](docs/screenshots/dashboard/2026-08-21/README.md)에서
24개 화면과 캡처 조건을 확인할 수 있습니다.

## 먼저 실행하기

### 로컬 소스에서 실행

OCaml 의존성을 한 번 설치한 뒤 작업 공간 서버를 실행합니다. 기본 quickstart는
Keeper를 시작하지 않으며 모델 프로바이더 키도 요구하지 않습니다.

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc

scripts/opam-pin-external-deps.sh --install
opam install . --deps-only
./quickstart.sh

BASE_PATH="${MASC_QUICKSTART_HOME:-$HOME/masc-quickstart}"
source "$BASE_PATH/.masc/config/mcp-client.env"
curl http://127.0.0.1:8935/health
```

기본값은 다음과 같습니다.

- 런타임 상태: `~/masc-quickstart/.masc`
- HTTP 포트: `8935`
- 대시보드: `http://127.0.0.1:8935/dashboard/`
- MCP 주소: `http://127.0.0.1:8935/mcp`
- Keeper 구성: 없음
- 런타임: `config/runtime.toml`의 현재 `[runtime].default`
- MCP bearer export: `~/masc-quickstart/.masc/config/mcp-client.env`

`--base-path`, `--team`, `--port`, `--no-open`, `--no-start` 옵션은
`./quickstart.sh --help`에서 확인할 수 있습니다.

`classic` Keeper 구성을 함께 시작하려면 첫 실행 때 모델 키를 제공합니다.

```bash
export OLLAMA_CLOUD_API_KEY=...
./quickstart.sh --team classic
```

필요한 OCaml과 Dune 버전은 `dune-project`에 적혀 있습니다. 첫 소스 실행은
OCaml 서버와 대시보드를 빌드하므로 몇 분 걸릴 수 있습니다.

### 공개 바이너리 설치

공개 릴리스는 `main`보다 늦을 수 있습니다. 먼저
[GitHub Releases](https://github.com/jeong-sik/masc/releases)에서 설치할 태그를
고르세요. 설치 스크립트도 같은 태그에서 내려받아야 새 설치 스크립트와 예전
릴리스 파일을 섞지 않을 수 있습니다.

```bash
TAG=vX.Y.Z
curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/${TAG}/scripts/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG"
```

설치 방식은 선택한 태그에 따라 달라집니다. 최근 릴리스의 스크립트는
`SHA256SUMS`가 있으면 내려받은 파일을 검증하고, 필요한 파일이 없으면 설치를
중단합니다. 지원 플랫폼은 각 릴리스에 첨부된 파일을 기준으로 확인하세요. 설치가
끝나면 스크립트가 출력한 login과 시작 명령을 따릅니다. login 명령은 MCP
클라이언트용 worker bearer를 만듭니다. 기본 설정의 MCP endpoint는 인증 없는
클라이언트를 받지 않습니다.

## MCP 클라이언트 연결

공개 MCP 경로는 HTTP입니다. 먼저 `quickstart.sh`가 만든 worker bearer를 현재
셸에 읽습니다.

```bash
BASE_PATH="${MASC_QUICKSTART_HOME:-$HOME/masc-quickstart}"
source "$BASE_PATH/.masc/config/mcp-client.env"
```

bearer 환경 변수를 지원하는 클라이언트에는 다음 형태로 등록합니다.

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
bearer_token_env_var = "MASC_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream" }
```

클라이언트가 연결되면 아래 두 호출로 첫 작업을 시작할 수 있습니다.

```text
masc_start(path="/path/to/project", task_title="첫 작업 설명")
masc_status()
```

`masc_start`는 작업할 프로젝트를 선택하고 작업 공간에 참여합니다. 제목을
전달하면 새 작업을 만들고 자신이 맡습니다. 이후 MASC 도구를 통해 목표, 작업,
보드 글, 상태 변경을 다른 에이전트와 공유합니다.

기본 로컬 인증에서는 URL만 등록하면 `401 Unauthorized`가 납니다. 다른
클라이언트 형식, initialize 직접 확인, 수동 bearer 생성은
[`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md)를 참고하세요. admin 전용 대시보드
작업은 [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md)에
정리돼 있습니다.

## 현재 범위

| 영역 | 현재 용도 | 알아둘 점 |
|---|---|---|
| 작업 공간 협업 | MCP로 목표(Goal), 작업(Task), 담당자, 상태 변경, 보드 글, 검증 근거를 공유합니다 | 협업 정보는 여러 에이전트가 동시에 같은 소스 파일을 고칠 때 발생하는 충돌을 완전히 막지 못합니다 |
| Keeper | 설정된 에이전트가 작업 공간의 이벤트를 받아 작업하고 실행 기록을 남깁니다 | 고급 기능이며 선택한 런타임과 Keeper 설정에 따라 동작이 달라집니다 |
| 대시보드 | 작업 공간과 런타임 상태를 보고 운영 명령을 실행합니다 | 대시보드 빌드 상태와 인증 방식에 따라 화면 및 쓰기 권한이 달라집니다 |
| Gate와 사람 승인 | 지원하는 외부 작업에 Always Allow, 모델 판단, 사람 승인을 적용합니다 | 승인 절차이며 샌드박스나 자격증명 보호 장치가 아닙니다 |
| 런타임 선택 | Keeper마다 프로바이더와 모델을 지정하고 순서가 있는 후보 목록을 설정합니다 | 올바른 카탈로그와 프로바이더 자격증명이 필요합니다 |
| Fusion | `masc_fusion`으로 여러 모델의 답과 심판 결과를 모읍니다 | 사용 전에 preset과 심판 런타임을 설정해야 합니다 |
| 외부 채널 | Discord와 Slack 등 지원 채널을 작업 공간에 연결합니다 | token과 채널별 Keeper 연결을 운영자가 직접 설정해야 합니다 |
| 로컬 또는 Docker 실행 | Keeper의 셸 작업에 `local` 또는 `docker`를 선택합니다 | `local`은 호스트에서 실행됩니다. Docker도 완전한 보안 경계가 아닙니다 |
| IDE와 TUI | 실험 중인 화면과 터미널 UI를 살펴봅니다 | 일반 작업을 시작하는 기본 경로가 아닙니다 |

현재 제품의 기본 경로는 저장소 작업 공간 협업입니다. Keeper 운영과 운영자
기능은 그다음 단계입니다. 원격 환경의 안전성, 클러스터 배포, 운영 서비스 수준은
현재 보장하지 않습니다. 범위와 우선순위는
[`docs/PRODUCT-OPERATING-PLAN.md`](docs/PRODUCT-OPERATING-PLAN.md)를 참고하세요.

## 설정

MASC는 런타임 상태를 `<base-path>/.masc` 아래에 둡니다. 사용자가 작성하는
설정은 기본적으로 `<base-path>/.masc/config`에 있습니다. `MASC_CONFIG_DIR`를
지정하면 다른 설정 폴더를 사용할 수 있습니다.

| 경로 | 용도 |
|---|---|
| `runtime.toml` | 프로바이더와 모델 목록, 필수 `[runtime].default`, 런타임 후보 목록, Keeper별 런타임 지정 |
| `agent-core-models-overlay.toml` | 배포 환경에서 추가하는 모델 기능 정보. 파일이 없으면 Agent Core에 포함된 기본 카탈로그만 사용합니다 |
| `keepers/<name>.toml` | Keeper 실행 설정 |
| `keepers/<name>/AGENT.md` | Keeper의 전체 프롬프트. TOML로 만든 Keeper마다 필요합니다 |
| `repositories.toml` | 저장소 작업에 사용할 저장소 이름과 체크아웃 정보 |
| `keeper_repo_mappings.toml` | Keeper별 저장소 선호값. 기본 선택에만 쓰며 접근 권한을 제한하지 않습니다 |
| `.env.local` | 현재 설치 스크립트와 빠른 실행 절차가 기록하는 프로바이더 환경 변수 |

Keeper 하나에는 사용자가 작성하는 파일 두 개가 필요합니다.

```text
<base-path>/.masc/config/keepers/reviewer.toml
<base-path>/.masc/config/keepers/reviewer/AGENT.md
```

```toml
# keepers/reviewer.toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "local"
mention_targets = ["operator"]
allowed_paths = ["workspace/yousleepwhen/masc"]
```

```markdown
<!-- keepers/reviewer/AGENT.md -->
현재 변경 내용을 검토하고, 파일 경로와 실행 명령을 포함한 근거를 보고하세요.
```

Keeper TOML에는 실행 설정만 둡니다. 프롬프트는 `AGENT.md`에 작성합니다.
정의되지 않은 Keeper TOML 항목이 있으면 설정을 거부합니다.

Keeper별 런타임은 `runtime.toml`에서 지정합니다.

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

전체 파일 규칙은 [`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md)에
있습니다. 실제로 적용된 설정은 `masc_config` 도구나
`/api/v1/dashboard/config`에서 확인할 수 있습니다.

## 실행 방식

| 명령 | 용도 |
|---|---|
| `masc start --base-path <path>` | 설치된 바이너리 실행. 하위 명령 없이 `masc`만 실행해도 같습니다 |
| `./start-masc.sh --http --base-path <path>` | 소스 checkout에서 전체 런타임 실행 |
| `scripts/start-loopback.sh` | Keeper 자동 시작을 기본으로 끈 채 `127.0.0.1:8935`에서 실행 |
| `scripts/run-local.sh --target-dir <path>` | 경로에서 계산한 포트로 격리된 개발 런타임 실행 |

상태 파일을 확인하거나 고치기 전에 서버가 실제로 사용하는 경로부터 확인하세요.

```bash
curl -fsS 'http://127.0.0.1:8935/health?full=1' \
  | jq '.paths | {effective_base_path, effective_masc_root, roots_diverge}'
```

`.masc/config/` 밖에서 서버가 만든 파일은 설정 입력이 아닙니다. Keeper 상태,
작업 저장소, 보드 로그, 실행 기록, 승인 이력을 직접 고치지 마세요.

## 대시보드

서버는 `/dashboard/`에서 대시보드를 제공합니다. 화면 구성은
`dashboard/src/config/navigation.ts`에 정의되어 있습니다.

사이드바의 기본 화면은 다음과 같습니다.

| 화면 | 용도 |
|---|---|
| Overview | 작업 공간과 런타임 요약 |
| Keepers | Keeper 목록, 대화, 현재 작업 맥락 |
| Registry | Keeper 설정과 런타임 연결 |
| Monitor | Keeper 목록, 도구 상태, 런타임, 관찰 기록 |
| Work | 목표, 계획, 저장소, 검증 상태 |
| Gate | 사람 승인 대기 목록과 Always 규칙 |
| Schedule | 예약 작업과 깨우기 신호 |
| Board | 사람, 에이전트, 자동화, 시스템 글 |
| Fusion | 패널과 심판 실행 결과 |
| Logs | 런타임 이벤트 로그 |
| IDE | 실험 중인 협업 IDE 화면 |
| Connectors | 외부 채널 상태와 Keeper 연결 |
| Settings | 운영 설정 화면 |

화면 안에서 선택할 수 있는 하위 항목은 다음과 같습니다.

| 화면 | 하위 항목 |
|---|---|
| Monitor | `agents`, `internal-agents`, `fleet-health`, `runtime`, `observatory` |
| Work | `work`, `planning`, `repositories`, `verification` |
| Connectors | `connector-status` |
| IDE | `ide-shell` |
| Lab | `tools`, `harness`, `performance`, `keeper-memory-health` |

`Lab`과 `Command`는 주소로 열 수 있지만 기본 사이드바에는 없습니다. 숨겨진
진단 화면은 사용자가 보는 기본 메뉴에 포함되지 않습니다.

현재 대시보드에서 지원하는 주소 예시는
`dashboard#monitoring?section=journey`,
`dashboard#command?section=operations`,
`dashboard#connectors?section=connector-status`,
`dashboard#workspace?section=verification`입니다. `journey`는 메뉴에 표시되지 않는
진단 화면입니다.

[24개 화면 목록](docs/screenshots/dashboard/2026-08-21/README.md)에서 기본 화면과
Monitor, Work, Lab 화면을 확인할 수 있습니다.

## 저장소 구조

```text
masc/
├── bin/          서버와 CLI 시작점
├── lib/          작업 공간, Keeper, 런타임, Gate, 서버 코드
├── packages/     저장소에 포함된 Agent Core 패키지
├── dashboard/    TypeScript와 Preact 대시보드 소스
├── assets/       빌드된 웹 파일
├── config/       초기 설정에 사용하는 기본 파일
├── docs/         실행 안내, 계약, 스펙, 이전 RFC
├── scripts/      빌드, 설치, 검사, 로컬 운영 스크립트
└── test/         OCaml 테스트와 테스트 데이터
```

## 문서

| 문서 | 용도 |
|---|---|
| [`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md) | MCP 클라이언트 설정 |
| [`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md) | 현재 Keeper 파일과 런타임 지정 규칙 |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | 로컬 토큰 발급과 대시보드 쓰기 권한 |
| [`docs/AGENT-CORE-BOUNDARY.md`](docs/AGENT-CORE-BOUNDARY.md) | MASC와 저장소에 포함된 Agent Core의 역할 구분 |
| [`docs/spec/SPEC-INDEX.md`](docs/spec/SPEC-INDEX.md) | 스펙 목록. 최신이라고 표시하지 않은 개수와 규모 정보는 과거 기록입니다 |
| [`docs/RELEASE-EVIDENCE.md`](docs/RELEASE-EVIDENCE.md) | 릴리스 근거 형식. 다시 쓸 때는 문서의 버전부터 확인해야 합니다 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 빌드, 테스트, pull request 작업 방식 |
| [`ROADMAP.md`](ROADMAP.md) | 현재 계획. 릴리스 약속은 아닙니다 |

## 개발 및 릴리스 상태

- 패키지 버전은 `dune-project`에 정의되고 `masc.opam`에 반영됩니다.
- 소스 릴리스 기록은 `CHANGELOG.md`에 있습니다.
- 공개 바이너리와 지원 플랫폼은
  [GitHub Releases](https://github.com/jeong-sik/masc/releases)의 첨부 파일을
  기준으로 확인합니다.
- 1.0 전에는 API와 설정 형식이 바뀔 수 있습니다.

## 라이선스

MIT. 자세한 내용은 [`LICENSE`](LICENSE)를 참고하세요.
