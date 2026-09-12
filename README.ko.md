# MASC

[![OCaml](https://img.shields.io/badge/OCaml-5.5-orange.svg)](https://ocaml.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[English](README.md)

MASC(Multi-Agent Shared Context)는 저장소 하나에 코딩 에이전트 여럿을 붙여
돌리는 하네스입니다. OCaml 바이너리 하나로, 내 컴퓨터에서 돌아갑니다. 프로젝트의
목표, 작업, 담당, 보드 글, 승인, 실행 기록을 `.masc/` 디렉터리 한 곳에 두고, 그
상태를 MCP로 열어 어떤 MCP 클라이언트든 들어오게 하고, 전부를 터미널 UI로 보여
줍니다.

**개발 방향:** 맡긴 변경을 끝까지 확인하고, 끊기면 이미 적용된 결과를 확인해
남은 작업을 이어갑니다. 이 보장을 유지하며 동시 작업 규모를 늘리는 것이 목표입니다.
[완료·복구·규모 확장 로드맵](docs/RELIABLE-CHANGE-ROADMAP.md)에 측정 가능한 Goal과
현재 구현된 부분, 앞으로 증명할 보장을 구분했습니다.

하는 일은 셋입니다.

- **에이전트가 같이 쓰는 상태.** 같은 체크아웃에서 에이전트 둘을 돌리면 각자
  자기 기억만 가집니다. 같은 결정을 다시 내리고, 같은 파일을 잡고, 상대가 이미
  해 본 걸 못 봅니다. MASC는 그 상태를 에이전트 밖으로 꺼내 둘 다 읽고 쓰는 한
  곳에 둡니다.
- **감독 아래 도는 상주 에이전트.** *Keeper*는 서버가 띄우고 지켜보는
  에이전트입니다. 샌드박스 안에서 턴을 돌리고, 파일을 고치고, 한 일을 올립니다.
  작업 공간 밖으로 나가는 호출(Jira, GitHub, Slack 등)은 사람이나 모델이 답하는
  Gate를 거칩니다.
- **터미널이 정문.** 터미널에서 `masc`를 치면 TUI가 열립니다. Keeper 목록,
  대화와 도구 호출, 승인 대기열, 보드, 계획, 저장소, diff, 서버 로그가 여기
  있습니다. 포트에 아무도 없으면 TUI가 서버를 먼저 띄웁니다.

> **개발 상태.** 1.0 이전이고, 믿을 수 있는 내 컴퓨터 안에서 쓰는 걸 전제로
> 합니다. 운영 서비스가 아니고 보안 경계도 아닙니다. Gate와 샌드박스는 특정
> 작업을 막지만, 사람이 보지 않는 사이 에이전트가 하는 위험한 일을 전부 막지는
> 못합니다. 설치 계약은 0.35.5 기준입니다. 제공되는 바이너리는
> [GitHub Releases](https://github.com/jeong-sik/masc/releases)에서 확인하세요.

![MASC 터미널 UI](docs/screenshots/tui/2026-09-04/surfaces/01-overview.png)

캡처 속 Keeper 이름과 경로는 같은 글자 수의 가짜 값으로 바꿨습니다.
[나머지 네 장](docs/screenshots/tui/2026-09-04/surfaces/README.md)과 캡처
조건은 같은 디렉터리에 있습니다.

## 들어가는 길

| 길 | 이럴 때 | 여는 법 |
|---|---|---|
| **TUI** | Keeper를 지켜보고 지시하고, Gate에 답하고, 도구 호출과 코드, diff, blame, 메모리를 볼 때 | 터미널에서 `masc`. 이름으로 부르면 `masc-tui` |
| **MCP** | 내가 쓰는 에이전트를 작업 공간에 넣을 때. 작업을 잡고, 보드에 쓰고, 증거를 남깁니다 | MCP 클라이언트로 `http://127.0.0.1:8935/mcp`에 bearer와 함께 |
| **대시보드** | 같은 상태를 브라우저에서 볼 때 | 같은 서버의 `/dashboard/`. 0.35.5 설치 스크립트는 바이너리와 일치하는 번들을 설치합니다 |

셋 다 같은 `.masc/`를 읽고 씁니다. 운영자용 새 기능은 TUI에 먼저 들어갑니다.
대시보드는 빌드되고 사실을 보여 주는 상태로 유지하지만, 제품이 자라는 곳은
아닙니다([대시보드](#대시보드) 참고).

## 설치

### 첫 대화: 0.35.5

먼저 보유한 모델 CLI에 로그인하거나 API 인증 환경변수를 설정하고 Docker를
시작하세요. 설치 화면에서 **↑/↓, Space, Enter**로 모델을 여러 개 선택한 뒤
imp의 기본 연결과 대체 순서를 고릅니다. 마법사는 저장 전에 각 모델의 응답과
도구 사용을 확인합니다. Context 한도는 연결의 메타데이터에서 읽으며, 알 수
없는 경우 다시 선택하거나 고급 입력을 사용할 수 있습니다.
Z.AI 인증 환경변수는 `ZAI_API_KEY`입니다. 다음 명령으로 imp를 시작합니다.

```bash
masc setup --base-path "$HOME/masc-workspace"
```

기본 이미지를 준비하고 작업 공간 서버와 `imp`를 시작한 뒤 TUI를 엽니다.
대화 응답, Board 글·Task 생성, 샌드박스 디렉터리 조회를 확인하세요.
“WebFetch로 지금 https://example.com 을 가져와서 HTTP 상태와 페이지 제목을 알려줘.”라고 요청하세요. [첫 대화 절차](docs/INSTALL.ko.md)를 따르세요.
바이너리 제공 여부는 [GitHub Releases](https://github.com/jeong-sik/masc/releases)에서 확인하세요.

### 공개 바이너리

[GitHub Releases](https://github.com/jeong-sik/masc/releases/tag/v0.35.14)에
첨부된 설치 스크립트를 받습니다. 선택한 릴리스의 자산을 검증하고 설치합니다.

> Installation target: v0.35.14 (check tag availability on GitHub Releases).

```bash
TAG=v0.35.14
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG"
```

선택 사항: 실행 전에 스크립트를 읽으려면 `less /tmp/masc-install.sh`를 실행하세요. `q`를 눌러 나간 다음 위의 `bash` 설치 명령을 실행합니다.

재설치할 때 `--force`나 `--wizard`는 `bash /tmp/masc-install.sh` 명령 끝에 붙입니다. `export PATH=...`에는 설치 옵션을 붙이지 마세요.

설치 스크립트는 `SHA256SUMS`를 필수로 검증하고 릴리스 실행 파일을 설치한 뒤, 처음 한 번 설정 마법사를 돌립니다(`--no-wizard`로 건너뜁니다).
0.35.5의 마법사는 방향키와 체크박스로 여러 모델 연결을 선택합니다.
선택한 모델의 실제 응답과 무해한 도구 호출을 확인한 뒤 imp의 기본 연결과
대체 순서를 반영하고 다른 연결은 보존합니다. API 키 값은 묻지 않고 환경변수 이름만 받으며 서버는 시작된 환경에서
키를 읽습니다. `--provider <id>`로 기존 프로바이더를 선택할 수 있습니다.
기본 `imp`는 Docker를 설치·시작한 뒤 `masc setup`으로 이미지를 준비하고 실행합니다.

릴리스 **0.35.5**은 Intel Mac, `masc-browser-host`, 바이너리와 일치하는
대시보드 번들을 포함하고 `--force` 재설치에서 기존 설정을 보존합니다.
macOS 설치기는 Python과 실행 라이브러리를 함께 제공하므로 MASC 설치에 Homebrew가 필요하지 않습니다. Apple Silicon은 macOS 14 이상, Intel은 macOS 15 이상이 필요합니다. 플랫폼별 준비물, 설치 파일,
첫 실행과 업그레이드는 [설치 가이드](docs/INSTALL.ko.md)에 정리했습니다.

### 소스에서

Git, opam, C 개발 도구, Node.js 22와 Corepack을 먼저 설치합니다. Native
라이브러리와 재현 가능한 빌드 절차는 [Release workflow](.github/workflows/release.yml)를
참고합니다. 체크아웃에서 대시보드를 쓰려면 아래 frontend 빌드도 필요합니다.
코딩 에이전트는 [저장소 실행 프로토콜](docs/constitution.xml)에 따라 CI에서 빌드합니다.

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
opam init --bare
opam switch create . ocaml-base-compiler.5.5.1
eval "$(opam env)"
scripts/opam-pin-external-deps.sh
opam install . --deps-only
opam exec -- dune build bin/main_eio.exe bin/masc_tui.exe
corepack enable
corepack prepare pnpm@10.31.0 --activate
(cd dashboard && pnpm install --frozen-lockfile)
scripts/build-dashboard-if-needed.sh --force
```

컴파일러와 Dune 버전은 `dune-project`에 고정돼 있습니다. 첫 빌드는 몇 분
걸립니다. Dune은 두 프로그램을 `_build/default/bin/main_eio.exe`(서버와
CLI)와 `_build/default/bin/masc_tui.exe`(TUI)에 둡니다. `masc`는 자기 옆이나
`PATH`에서 `masc-tui`라는 이름으로 TUI를 찾기 때문에, 이름을 붙여 주기 전까지
체크아웃의 `masc`는 TUI 대신 서버를 띄웁니다.

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/_build/default/bin/main_eio.exe" ~/.local/bin/masc
ln -sf "$PWD/_build/default/bin/masc_tui.exe" ~/.local/bin/masc-tui
```

`./quickstart.sh`는 `~/masc-quickstart` 아래에 작업 공간을 만들고, 서버를
띄우고, MCP bearer를 `.masc/config/mcp-client.env`에 씁니다. Keeper는 띄우지
않고 프로바이더 키도 필요 없습니다. `--team classic`을 주면 Keeper 프리셋을
만들고, 그때는 셸에 `OLLAMA_CLOUD_API_KEY`가 있어야 합니다.

## 실행

| 명령 | 하는 일 |
|---|---|
| `masc` | 터미널에서는 TUI를 엽니다. 포트에 아무도 없으면 서버부터 띄웁니다. 터미널이 아닌 곳(파이프, 유닛 파일, 컨테이너, CI)에서는 서버가 뜹니다 |
| `masc start --base-path <dir>` | 터미널이든 아니든 서버를 띄웁니다 |
| `masc-tui --base-path <dir>` | TUI를 이름으로 엽니다 |
| `masc setup --base-path <dir>` | Docker를 준비하고 기존 `imp`를 시작한 뒤 TUI를 엽니다(0.35.5) |
| `masc init --base-path <dir>` | 바이너리에 든 자산으로 `.masc/config/`를 만듭니다. Keeper `imp` 하나가 `activation_mode = "manual"`로 들어갑니다 |

`--base-path`는 `.masc`를 담은 디렉터리이지 `.masc` 자체가 아닙니다. 없으면
`MASC_BASE_PATH`, 그다음 현재 디렉터리를 씁니다. 실행 상태는
`<base-path>/.masc` 아래, 직접 쓰는 설정은 `<base-path>/.masc/config` 아래에
있습니다.

나머지 하위 명령: bearer 관련 `login`, `mcp-config`, `token`. Keeper 관련
`keeper-create`, `keeper-github`. 기본 샌드박스 이미지 `sandbox-image`. 모델
런타임 관련 `runtime-default-set`, `runtime-probe`, `runtime-wizard-catalog`.
그리고 `schedule-prune`, `build-commit`. 각각 `masc <command> --help`에
설명이 있습니다.

서버가 떠 있으면 `curl http://127.0.0.1:8935/health`가 답합니다. 상태 파일을
손으로 만지기 전에 서버가 실제로 어느 루트를 쓰는지 확인합니다.

```bash
curl -fsS 'http://127.0.0.1:8935/health?full=1' \
  | jq '.paths | {effective_base_path, effective_masc_root, roots_diverge}'
```

`.masc/` 아래에서 `config/`와 `skills/`를 뺀 나머지는 서버가 관리합니다.
Keeper 스냅샷, 작업 저장소, 보드 로그, 영수증, 승인 이력은 손으로 고치지
않습니다.

## 터미널 UI

TUI는 입력 가능한 TTY와 `dumb`이 아닌 터미널이 필요합니다. 포트에 아무도
없으면 옆에 있는 `masc` 바이너리를 자식 프로세스로 띄우고 `/health`를 기다린
뒤, 자기가 끝날 때 그 자식도 끝냅니다. 이미 떠 있던 서버는 건드리지 않습니다.

`Tab`과 `Shift-Tab`으로 화면 열 개를 돌아다닙니다. 맨 윗줄에 띠로 그려집니다.
자식 화면은 전부 `:` 팔레트의 `go <name>` 항목이기도 합니다.

| 화면 | 보여 주는 것 |
|---|---|
| Overview | 작업 공간 요약, 작업 백로그, 지금 봐야 할 것 |
| Activity | 모든 Keeper의 도구 호출, 턴 경계, 정산이 도착하는 대로. `l`로 서버 자체 로그를 엽니다 |
| Keepers | Keeper 목록. Keeper마다 대화, 로그, 도구 호출, 런타임, 샌드박스 상태, 기록된 파일 쓰기, 채널, 스케줄, 상세 탭 |
| Memory | Keeper별 메모리 상태와 두 저장소를 아우르는 사실 탐색기 |
| Approvals | Gate 대기열, 항상 허용 규칙, Keeper가 답을 기다리는 질문 |
| Board | 사람, 에이전트, 자동화, 시스템이 올린 글 |
| Planning | 목표, 계획, 작업 검토 대기열, 기록된 판정 |
| Fusion | 패널과 심사 실행, 그 증거 |
| Workspace | 등록된 저장소. `Enter`로 파일 탐색기가 열리고 diff, 이력, blame, 메모, 언어 서버 hover와 정의를 봅니다 |
| Config | 서버가 읽는 그대로의 `runtime.toml`(`e`로 `$EDITOR`에서 편집), 프롬프트, 테마, 런타임 레인과 프로바이더 도달 여부, MCP 리소스 목록, 영수증이 딸린 도구 목록 |

어디서나 되는 키: `?` 도움말, `:` 명령 팔레트, `r` 새로고침, `q` 두 번
종료. `/`는 Keeper 목록, Code 트리, 대화의 요청 탭에서 검색합니다.

맨 아래 입력줄은 이름을 댄 Keeper에게 메시지를 보냅니다. `/task <title>`은
작업을 만들고 같은 메시지로 Keeper에게 그 id를 건넵니다. 나머지는 `/help`에
있습니다. Keeper가 `masc_ask`로 물어본 질문도 같은 줄에서 답합니다. 대화 속
도구 호출은 JSON 구조 그대로 트리로 그려지고, 대화 옆 컨텍스트 창은 각 턴에
뭐가 들어갔고 프로바이더가 뭐라고 답했는지 보여 줍니다.

Code 화면은 프로젝트 언어에 맞는 언어 서버(`ocamllsp`,
`typescript-language-server`, `pyright-langserver`, `rust-analyzer`, `gopls`,
`clangd` 등)를 `PATH`에서 찾아 띄웁니다. MASC가 들고 있는 언어 서버는
없습니다. 없는 서버는 짐작 대신 `Command_not_found`로 답합니다.

서버가 없어도 Keeper 목록, Keeper 상세, 작업 백로그는 디스크에서 읽습니다.
나머지는 빈 목록을 그리는 대신 서버가 필요하다고 말합니다. TUI와 서버가 다른
루트를 보고 있으면 헤더에 `[workspace mismatch]`가 뜹니다.

키 전체, 화면별 동작, 테마, 브라우저 레인, 문제 해결은
[`docs/TUI-GUIDE.md`](docs/TUI-GUIDE.md)에 있습니다.

## MCP로 에이전트 붙이기

`masc mcp-config`가 bearer를 만들고 지정한 클라이언트용 설정 블록을
출력합니다.

```bash
masc mcp-config --base-path /path/to/project --client codex
masc mcp-config --base-path /path/to/project --client claude-desktop
masc mcp-config --base-path /path/to/project --client env   # 셸 export
```

오래 가는 worker 토큰을 만들고(`--expiring`이면 세션용) 엔드포인트, 토큰,
헤더를 블록에 넣어 줍니다. URL만 적은 클라이언트 설정은 `401 Unauthorized`를
받습니다. 로컬 기본값은 인증 없는 클라이언트를 받지 않습니다.

이 명령이 모르는 클라이언트도 조각은 같습니다. Codex:

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
bearer_token_env_var = "MASC_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream" }
```

Claude Desktop은 [`mcp-remote`](https://github.com/punkpeye/mcp-remote#custom-headers)를
거칩니다. `npx`용 Node.js/npm이 필요하며, 아래 header가 토큰을 HTTP 인증에 연결합니다.

```json
{
  "mcpServers": {
    "masc": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:8935/mcp",
        "--header", "Authorization: Bearer ${MASC_TOKEN}"],
      "env": { "MASC_TOKEN": "여기에-토큰" }
    }
  }
}
```

### 토큰

- `masc login --agent <name> --client-env MASC_TOKEN`은 에이전트 이름 하나에
  bearer 하나를 만듭니다. 같은 이름으로 다시 만들면 이전 bearer는 바로
  무효가 됩니다. 따로 폐기할 건 없습니다.
- 저장소에는 토큰의 SHA-256만 `.masc/auth/agents/<agent>.json`에 남습니다.
  원본은 `.masc/auth/<agent>.token`(권한 `0600`)과 export한 셸에만 있습니다.
- `masc token list`, `masc token revoke <agent>`, `masc token prune`으로
  확인하고, 폐기하고, 만료된 것을 정리합니다.

### 작업 공간에서 에이전트가 하는 일

에이전트는 작업, 점유, 상태 전이로 서로 맞춥니다. 아래 이름은 서버가 노출하는
MCP 도구입니다. 정확한 목록은 세션에서 `tools/list`로 확인합니다.

```text
# 에이전트 A가 참여하고 작업을 점유
masc_start(path="/path/to/project", task_title="Fix auth token refresh")
masc_transition(task_id="task-001", action="claim")

# 에이전트 B가 참여해서 task-001이 잡힌 걸 보고 다른 작업을 잡음
masc_start(path="/path/to/project")
masc_status()
masc_add_task(title="Write integration test for auth flow")
masc_transition(task_id="task-002", action="claim")

# 에이전트 A가 증거와 함께 제출
masc_transition(
  task_id="task-001",
  action="submit_for_verification",
  handoff_context={
    "summary": "Token refresh tests passing",
    "evidence_refs": ["artifact:tests/auth_test.log"]
  }
)
```

Goal은 주인이 따로 없는, 같이 갖는 목표입니다. `masc_goal_upsert`는
`metric`과 `target_value`를 꼭 받고,
`masc_goal_transition(action="request_complete")`는 작업 증거를 읽는 모델
심판에게 목표를 넘겨 판정을 기록하게 합니다.

다른 클라이언트 형식과 `initialize` 직접 호출은
[`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md)에 있습니다.

## Keeper

Keeper는 `<base-path>/.masc/config/keepers/` 아래 TOML 파일 하나입니다.
서버가 띄우고, 보드 멘션·타이머·미배정 작업에 깨우고, 턴마다 샌드박스에서
돌리고, Keeper가 쉬기 전에 그 턴의 기록을 `.masc/` 아래에 씁니다. 새 루트에는
Keeper `imp` 하나가 들어 있습니다. 설치 스크립트도 `masc init`도 서버도
바이너리의 `keepers-default/`에서 그 하나를 시드합니다. `activation_mode = "manual"`로 들어오므로 모델과 샌드박스를 갖추고 직접 시작하거나 `activation_mode = "autonomous"`로 바꾸기
전에는 아무것도 돌지 않습니다. `masc setup`으로 준비하고 시작할 수 있습니다.

```toml
[keeper]
activation_mode = "autonomous"
sandbox_profile = "docker"
sandbox_image = "node:22-bookworm"
network_mode = "none"
mention_targets = ["operator"]

instructions = """
You are the review Keeper. Inspect the current change and report concrete
evidence with file paths and commands.
"""

[keeper.tools]
native = "read"   # "none" | "read" | "full"
```

모르는 키는 거부합니다. 모델은 여기가 아니라 `runtime.toml`에서 배정합니다.

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

첫 턴이 돌기 전에 Keeper에게 필요한 것:

- **샌드박스.** `sandbox_profile`은 `docker`, `microvm`, `remote_ssh` 중
  하나입니다. 호스트에서 그냥 도는 프로파일은 없고, 받아들일 프로파일이 없는
  Keeper는 거부됩니다. `remote_ssh` Keeper는 `runtime.toml`의
  `[exec.ssh.endpoints]`에 선언한 `remote_endpoint`를 이름으로 댑니다.
- **이미지.** `docker`와 `microvm` 턴은 이미지 안에서 돌고, 이미지가 없으면
  턴마다 `docker_preflight_failed`에서 멈춥니다. `masc sandbox-image`가
  바이너리에 든 레시피로 `masc-sandbox:general`(Debian 위 bash, ripgrep, git)을
  만듭니다. 프로젝트를 빌드해야 하는 Keeper는 그 프로젝트 툴체인 이미지를
  `sandbox_image`에 적습니다. 컨테이너는 읽기 전용 rootfs, `--cap-drop=ALL`,
  내 uid로 돌기 때문에 `bash`와 툴체인이 이미지에 미리 있어야 합니다. 턴 도중에
  뭘 설치할 수는 없습니다.
- **네트워크 모드.** 샌드박스는 `network_mode = "none"`으로 시작합니다. 웹
  검색도, `git push`도, HTTP도 안 됩니다. `inherit`는 호스트 네트워크를 줍니다.
  `policy`는 `runtime.toml`의 `[egress.keepers.<name>]`에 적은 목적지만, 서버가
  가진 프록시를 거쳐 열어 줍니다. `masc keeper-create`는 `--network-mode`를
  꼭 받고 대신 골라 주지 않습니다.
- **서버 환경의 프로바이더 키.** `runtime.toml`이 프로바이더마다 변수 이름을
  정하고, 서버는 자기가 시작된 셸에서 그 변수를 읽습니다. TUI로 들어올 때는
  TUI를 띄우기 전에 export해야 합니다. TUI가 띄우는 서버는 TUI의 환경을
  물려받습니다.

Keeper가 하는 일은 승인 레인 둘이 막습니다. 작업 공간 레인은 `auto_judge`로
시작합니다. 모델이 게이트에 걸린 호출을 읽고 결정합니다. 그 판단은 자기
레인(`hitl_auto_judge`)에서 돌고, 판단 못 하는 호출은 허용도 거부도 아닌 채
사람 몫인 Approvals 대기열로 넘어갑니다. 외부 서비스 레인, 즉 Jira, GitHub,
Slack 같은 붙인 서비스로 나가는 호출은 `manual`로 시작합니다. 첫 작업에서
멈춘 것처럼 보이는 Keeper는 대개 Approvals에서 기다리고 있습니다.

OAuth 커넥터는 선언이지 연결이 아닙니다. 갓 설치한 상태에서
`GET /api/v1/keepers/oauth/providers`는 모든 프로바이더에 `has_client: false`를
답합니다. 붙이려면 먼저 OAuth 클라이언트가 있어야 하고, Connectors 화면이나
`POST /api/v1/keepers/oauth/client`로 넣습니다. 채널 커넥터는 다릅니다.
Discord, iMessage, Slack은 서버 안에서 돌고, 토큰이 서버 환경에 있으면 바로
붙습니다. `DISCORD_BOT_TOKEN`을 export한 셸에서 띄운 서버는 base path가
임시 디렉터리여도 부팅과 함께 그 길드에 들어갑니다. Telegram은 사이드카를
거칩니다.

`microvm`은 하이퍼바이저 뒤 게스트를 뜻하고, 어느 런타임인지는
`microvm_backend`가 정합니다. 2026-09-04 macOS 26.6.1에서 잰 상태:

| `microvm_backend` | CLI | 상태 |
|---|---|---|
| `apple_container` | `container` | 돕니다. macOS의 기본값이고, `network_mode = "policy"`를 실을 수 있는 유일한 백엔드 |
| `microsandbox` | `msb` | 배선은 됐고 부팅은 안 됩니다. 게스트를 구분하지 못해 Keeper가 `microvm_container_listing_failed`에서 멈춥니다 |
| `nerdctl_kata` | `nerdctl` | Linux x64 에서 `Kata volume smoke` 워크플로로 한 번 확인했습니다(run 34194081312, 2026-09-08). Keeper 가 Kata 게스트 안에서 실행되고 작업 볼륨이 게스트 재생성 뒤에도 남습니다. 릴리즈 게이트에는 없고 macOS 에서는 재지 않았습니다. CLI가 없으면 이름을 대고 거부합니다 |

CLI가 없는 백엔드는 공유 커널로 바꿔치기하지 않고 부팅에서 거부합니다. macOS가
아닌 호스트에서는 백엔드를 직접 적어야 합니다.

문서: Keeper를 돌리고 지켜보는 법은
[`docs/KEEPER-USER-MANUAL.ko.md`](docs/KEEPER-USER-MANUAL.ko.md), 파일 계약은
[`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md), 외부 서비스 붙이기는
[`docs/KEEPER-IDENTITY-MANUAL.ko.md`](docs/KEEPER-IDENTITY-MANUAL.ko.md),
그리고 [egress 런북](docs/operations/egress-policy-runbook.md)과
[SSH 엔드포인트 런북](docs/operations/ssh-endpoints-runbook.md).

## 설정

직접 쓰는 설정은 `MASC_CONFIG_DIR`로 다른 루트를 정하지 않는 한
`<base-path>/.masc/config` 아래에 있습니다.

| 경로 | 용도 |
|---|---|
| `runtime.toml` | 프로바이더/모델 카탈로그, 필수인 `[runtime].default`, 런타임 레인, Keeper 배정, SSH 엔드포인트, egress 규칙, `[tui]` |
| `keepers/<name>.toml` | Keeper 하나. 운영 설정, 프롬프트 지시, 도구 권한 |
| `tools/*.toml` | 서버가 등록하는 도구의 선언형 스키마 |
| `repositories.toml` | Workspace 화면에 올릴 저장소 등록 |
| `agent-core-models-overlay.toml` | 내장 카탈로그 위에 얹는 모델 능력 행(선택) |
| `<base-path>/.masc/skills/<name>/SKILL.md` | Keeper에게 이름으로 건넬 수 있는 능력. frontmatter의 `name`은 디렉터리 이름과 같아야 합니다 |

런타임이 읽는 환경 변수는 [`docs/ENV-CONTRACT.md`](docs/ENV-CONTRACT.md)에,
어떤 프롬프트 파일이 누구에게 가는지는 [`docs/PROMPT-MAP.md`](docs/PROMPT-MAP.md)에
있습니다.

## 대시보드

서버가 `/dashboard/`에 TypeScript/Preact SPA를 제공합니다. 0.35.5 설치
스크립트는 실행 파일 prefix 아래에 같은 소스 커밋의 대시보드 번들을 설치하고
커밋과 파일 체크섬을 검증합니다. 사용하려고 Node.js나 소스를 설치하거나
프론트엔드를 빌드할 필요가 없습니다. 이미 실행 중인 서버는 재시작할 때 새
번들을 사용합니다. [배포 구조](docs/design/installed-dashboard-distribution.md)와
[설치 가이드](docs/INSTALL.ko.md)를 참고하세요. 이전 태그는 해당 태그의 설치
스크립트를 사용합니다.

대시보드는 TUI가 읽는 상태를 그대로 읽고, TUI에 없는 화면 둘(실험적인 IDE
셸, Lab 진단)을 아직 갖고 있습니다. 2026-09-07까지 두 주 동안 대시보드에
137건, TUI에 583건의 커밋이 들어갔습니다(전체 3,003건). 운영자 기능은 TUI에
먼저 만들고, 대시보드는 빌드되고 타입 검사를 통과하고 사실을 보여 주는
상태로 유지합니다.
[화면 24장 목록](docs/screenshots/dashboard/2026-09-04/README.md)과
[`docs/DASHBOARD-INTEGRATION.md`](docs/DASHBOARD-INTEGRATION.md)에 설명이
있습니다. 관리자 조작과 쓰기 권한은
[`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md)에
있습니다.

## 한계

- 공유 상태는 파일을 잠그지 않습니다. 에이전트 둘이 같은 파일을 고치면 여전히
  충돌합니다. MASC는 서로를 보게 해 줄 뿐 순서를 세워 주지 않습니다.
- Gate는 승인 절차이지 자격증명 경계가 아닙니다. 샌드박스는 턴이 닿을 수 있는
  범위를 줄이지만 어느 것도 완전한 보안 경계는 아니고, `remote_ssh`는
  엔드포인트의 네트워크를 그대로 씁니다.
- 인증 기본값은 루프백용입니다. 원격에서 안전하게 쓰기, 클러스터 배포, 서비스
  수준 보장은 약속하지 않습니다.
- 프로세스 하나가 작업 공간을 들고 있습니다. 대체 인스턴스는 없습니다.
- microVM Keeper는 `apple_container`에서만 부팅이 확인됐습니다. `auto_judge`는
  자기 레인에 모델이 있어야 하는데, 프로바이더 키 하나로 설치한 환경에는 대개
  없습니다. 그 호출은 사람을 기다립니다.
- TUI 화면과 키는 `main`에서 바뀝니다. 설치한 태그의 문서를 사용하세요.

## 저장소 구조

```text
masc/
├── bin/          서버와 CLI(main_eio.ml), TUI(masc_tui*.ml), exec shim, probe
├── lib/          작업 공간, Keeper, 런타임, Gate, 서버, TUI 디코딩
├── packages/     내장 Agent Core
├── dashboard/    TypeScript, Preact 대시보드 소스
├── connectors/   브라우저 레인 호스트
├── config/       바이너리에 내장되는 설정 시드
├── docs/         매뉴얼, 런북, 스펙, RFC, 연구 기록
├── scripts/      빌드, 설치, CI 린트, 로컬 운영
└── test/         Alcotest 스위트와 픽스처
```

## 문서

| 문서 | 용도 |
|---|---|
| [`docs/TUI-GUIDE.md`](docs/TUI-GUIDE.md) | TUI의 모든 화면, 키, 테마, 실패 상황 |
| [`docs/MCP-TEMPLATE.md`](docs/MCP-TEMPLATE.md) | MCP 클라이언트 설정과 `initialize` 직접 호출 |
| [`docs/KEEPER-USER-MANUAL.ko.md`](docs/KEEPER-USER-MANUAL.ko.md) | Keeper 설정, 시작, 지켜보기 |
| [`docs/KEEPER-FILE-MODEL.md`](docs/KEEPER-FILE-MODEL.md) | Keeper 파일과 런타임 배정 계약 |
| [`docs/KEEPER-IDENTITY-MANUAL.ko.md`](docs/KEEPER-IDENTITY-MANUAL.ko.md) | Jira, Notion, Google 등 외부 서비스를 Keeper에 붙이기 |
| [`docs/SKILLS.md`](docs/SKILLS.md) | `SKILL.md`로 능력을 선언하고 Keeper에게 건네기 |
| [`docs/ENV-CONTRACT.md`](docs/ENV-CONTRACT.md) | 런타임이 읽는 환경 변수 |
| [`docs/PROMPT-MAP.md`](docs/PROMPT-MAP.md) | 어떤 프롬프트 파일이 누구에게 가는지 |
| [`docs/operations/ssh-endpoints-runbook.md`](docs/operations/ssh-endpoints-runbook.md) | `remote_ssh` 엔드포인트 준비와 preflight 실패 코드 |
| [`docs/operations/egress-policy-runbook.md`](docs/operations/egress-policy-runbook.md) | `policy` Keeper가 닿을 수 있는 곳 선언하기 |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | 로컬 bearer와 대시보드 쓰기 권한 |
| [`docs/AGENT-CORE-BOUNDARY.md`](docs/AGENT-CORE-BOUNDARY.md) | MASC와 내장 Agent Core의 책임 경계 |
| [`docs/spec/SPEC-INDEX.md`](docs/spec/SPEC-INDEX.md) | 스펙 목록 |
| [`docs/RELEASE-EVIDENCE.md`](docs/RELEASE-EVIDENCE.md) | 릴리스 증거 형식 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 빌드, 테스트, 린트, PR 절차 |
| [`ROADMAP.md`](ROADMAP.md) | 지금의 계획. 릴리스 약속은 아닙니다 |

## 릴리스 상태

패키지 버전은 `dune-project`에 있고 `masc.opam`으로 생성됩니다.
`CHANGELOG.md`가 소스 릴리스 이력을 적고, 바이너리의 정답은 GitHub
Releases입니다. 현재 릴리스 계열은 **0.35.5**입니다.
1.0 전에는 API와 설정이 바뀔 수 있습니다.

## 라이선스

MIT. [`LICENSE`](LICENSE)를 보세요. 포함된 폰트의 라이선스는
[외부 저작물 고지](THIRD-PARTY-LICENSES.md)에 있습니다.
