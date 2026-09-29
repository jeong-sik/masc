<p align="center">
  <img src="docs/assets/candle.svg" alt="빨간 뿔과 따뜻한 불꽃을 가진 작은 촛불 Keeper" width="200" height="200">
</p>

<h1 align="center">MASC</h1>
<p align="center"><strong>에이전트와 함께 일하는 작업 공간.</strong></p>
<p align="center">
  <a href="README.md">English</a> ·
  <a href="#시작하기">시작하기</a> ·
  <a href="docs/TUI-GUIDE.md">TUI 가이드</a> ·
  <a href="https://github.com/jeong-sik/masc/releases">릴리스</a>
</p>
<p align="center">
  <a href="https://ocaml.org/"><img src="https://img.shields.io/badge/OCaml-5.5-orange.svg" alt="OCaml 5.5"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT license"></a>
</p>

MASC(**Multi-Agent Shared Context**)는 **Keeper**라는 상주 에이전트가 함께
일하는 공간입니다. Keeper들은 목표를 공유하고, 작업을 맡고, Board에서 대화하고,
결과를 검증에 제출합니다. 터미널 UI에서 함께 일하거나, MCP로 다른 에이전트를
연결하거나, 브라우저에서 작업 공간을 열 수 있습니다. OCaml 네이티브 서버가 내
컴퓨터에서 돌아가며, 설정과 작업 기록은 `<base-path>/.masc/`에 남습니다.

> **1.0 이전 버전입니다.** 신뢰할 수 있는 로컬 작업 공간을 전제로 개발하고 있으며,
> API와 설정은 바뀔 수 있습니다. 무인 실행이나 서버 공개 전에는 [한계](#한계)를
> 확인하세요. 이 README는 `main` 기준입니다. 설치한 버전의 동작은 해당 태그의 문서를 보세요.

## MASC로 하는 일

- **대화가 끝나도 작업을 남깁니다.** Keeper의 기록, 메모리, 작업과 결정이 작업
  공간에 남고, 각 턴에 어떤 맥락이 들어갔는지 살펴볼 수 있습니다.
- **에이전트가 함께 일할 바탕을 만듭니다.** Goal은 도달할 결과를, Task는 누가
  무엇을 하는지를 기록합니다. Board에서는 Keeper와 MCP 클라이언트가 대화합니다.
- **실행할 모델을 고릅니다.** 모델 제공자, 로그인한 CLI, 로컬 모델 서버를 설정하고
  Keeper마다 기본 연결과 대체 연결 순서를 지정합니다.
- **사람이 참여합니다.** TUI에서 도구 호출과 변경을 읽고, 질문에 답하고, 승인이
  필요한 행동을 결정합니다. Task 완료에는 검증이, Goal 완료에는 사람의 최종 확인까지 필요합니다.

맡긴 작업을 검증까지 잇고, 중단 뒤 복구하고, 동시 작업이 늘어도 이 흐름을 유지하는
것이 개발 목표입니다. [완료·복구·규모 확장 로드맵](docs/RELIABLE-CHANGE-ROADMAP.md)에
현재 구현된 기능과 앞으로 증명해야 할 보장을 구분했습니다.

## 시작하기

### 설치

바이너리 릴리스는 macOS(Apple Silicon·Intel)와 Linux(x86_64·ARM64)를 대상으로
합니다. 바이너리를 설치할 때는 OCaml이나 Node.js 개발 도구가 필요하지 않습니다.
[플랫폼 요구사항](docs/INSTALL.md#platforms-and-prerequisites)과
[배포된 파일](https://github.com/jeong-sik/masc/releases)을 확인하세요.

> Installation target: v0.48.0 (check tag availability on GitHub Releases).

```bash
TAG=v0.48.0
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh &&
bash /tmp/masc-install.sh --version "$TAG"
```

설치 스크립트는 `SHA256SUMS`를 검증하고 실행 파일과 같은 버전의 브라우저 대시보드를
설치한 뒤 설정 마법사를 제공합니다. 기본 실행 파일 위치는 `~/.local/bin`입니다.
PATH 추가 안내를 수락하거나 셸의 PATH에 직접 넣으세요. 스크립트를 먼저 살펴보려면
다운로드한 뒤 `less`로 읽고 `bash`로 실행하면 됩니다.

### 첫 Keeper 만나기

모델 CLI에 로그인하거나 제공자가 요구하는 API 인증 환경변수를 설정하세요.
마법사에서 **↑/↓, Space, Enter**로 모델을 선택하면 응답과 도구 사용을 확인한 뒤
기본 연결과 대체 순서를 묻습니다. 계정 한도로 검사를 못 한 경우도 표시합니다.
기본 샌드박스에는 Docker를 실행해 두세요. 필요한 샌드박스 도구가 없으면 설정 화면에서 안내합니다.

설치 뒤 설정 화면이 열리지 않았다면 다음을 실행하세요.

```bash
"$HOME/.local/bin/masc" setup --base-path "$HOME/masc-workspace"
```

설치 경로를 바꿨다면 그 경로를 사용하세요. 설정을 마치면 샌드박스를 준비하고 작업
공간 서버와 첫 Keeper인 `imp`를 시작한 뒤 TUI를 엽니다. 결과를 바로 확인할 수 있는
작은 부탁부터 해 보세요.

> 자기소개하고, 네 샌드박스 디렉터리를 보여 줘.
> 함께 할 만한 작업 하나를 Board에 글로 올려 줘.

Keeper 대화에서 답변과 도구 결과를 읽고, Board에서 글을 찾아보세요.
[첫 대화 가이드](docs/INSTALL.md#first-conversation-with-imp)에는 Task와 웹 접근을
확인하는 순서도 있습니다. macOS에서는 [음성으로 imp와 대화](docs/INSTALL.md#talking-to-imp-by-voice-macos)할 수도 있습니다.

업그레이드, 모델 검사 오류, 샌드박스 선택과 삭제 방법은 [설치 가이드](docs/INSTALL.ko.md)를 참고하세요.

<details>
<summary>소스에서 빌드하기</summary>

### 소스에서

Git, opam, C 개발 도구, Node.js 22, Corepack과 native 라이브러리를 먼저 설치합니다.

- Debian/Ubuntu: `pkg-config m4 libgmp-dev libssl-dev libzstd-dev
  libsqlite3-dev libpq-dev libev-dev libffi-dev zlib1g-dev libncurses-dev
  libprotobuf-dev protobuf-compiler`. `protoc`는 proto3 `optional`을 이해해야 합니다.
  Ubuntu 22.04 패키지의 3.12는 이를 지원하지 않으므로 더 새로운
  [upstream protoc](https://github.com/protocolbuffers/protobuf/releases)를 `PATH` 앞쪽에
  둡니다(릴리스 빌드는 25.1 사용, [`scripts/build-linux-release.sh`](scripts/build-linux-release.sh) 참고).
- macOS(Homebrew): `flock gmp libpq openssl@3 zstd protobuf`를 설치하고,
  [Release workflow](.github/workflows/release.yml)의 macOS 단계처럼 `openssl@3`와
  `libpq`에 맞춰 `PKG_CONFIG_PATH`, `CPATH`, `LIBRARY_PATH`를 export합니다.

체크아웃에서 대시보드를 쓰려면 아래 frontend 빌드도 필요합니다.
코딩 에이전트는 [저장소 실행 프로토콜](docs/constitution.xml)에 따라 CI에서 빌드합니다.

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
opam init --bare
opam switch create . ocaml-base-compiler.5.5.1 --no-install
eval "$(opam env)"
scripts/opam-pin-external-deps.sh
opam install ./masc.opam --deps-only --locked
opam exec -- dune build bin/main_eio.exe bin/masc_tui.exe
corepack enable
corepack prepare pnpm@10.31.0 --activate
scripts/build-dashboard-if-needed.sh --force
```

`--no-install`은 pin 스크립트가 opam-repository에 없는 의존성을 등록하기 전에
switch가 의존성을 풀려다 실패하지 않게 합니다. 컴파일러 버전은 `dune-project`에
고정돼 있고, `--locked`는 CI가 쓰는 정확한 Dune과 라이브러리 버전을
`masc.opam.locked`에서 설치합니다. 첫 빌드는 몇 분
걸립니다. Dune은 두 프로그램을 `_build/default/bin/main_eio.exe`(서버와
CLI)와 `_build/default/bin/masc_tui.exe`(TUI)에 둡니다. `masc`는 자기 옆이나
`PATH`에서 `masc-tui`라는 이름으로 TUI를 찾기 때문에, 이름을 붙여 주기 전까지
체크아웃의 `masc`는 TUI 대신 서버를 띄웁니다.

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/_build/default/bin/main_eio.exe" ~/.local/bin/masc
ln -sf "$PWD/_build/default/bin/masc_tui.exe" ~/.local/bin/masc-tui
```

대신 `scripts/install-local-build.sh`를 쓰면 `masc`, `masc-tui`, `masc-browser-host`를
한 번에 빌드해 `~/.local/bin`에 복사합니다. `eval "$(opam env)"`를 적용한 셸에서 실행하세요. 이 스크립트는 등록된
Firefox browser-lane host도 새 빌드로 다시 설치하고, 그 작업 공간에서 실행 중인 host 프로세스를
종료합니다. 확장은 새 사본으로 다시 연결합니다.

`./quickstart.sh`는 `~/masc-quickstart` 아래에 작업 공간을 만들고, 서버를
띄우고, MCP bearer를 `.masc/config/mcp-client.env`에 씁니다. Keeper는 띄우지
않고 프로바이더 키도 필요 없습니다. `--team classic`을 주면 Keeper 프리셋을
만들고, 그때는 셸에 `OLLAMA_CLOUD_API_KEY`가 있어야 합니다.


</details>

## 작업 공간의 구성

| 개념 | 하는 일 |
|---|---|
| **Keeper** | 지침, 모델 연결, 샌드박스와 작업 기록을 가진 상주 에이전트 |
| **Goal** | 측정 지표와 목표값을 가진 공동 목표. 검증 뒤 사람이 완료를 확인합니다 |
| **Task** | 담당, 실행 상태와 검증 증거를 가진 작업 단위. 독립적으로 존재하거나 Goal에 속합니다 |
| **Board** | 에이전트와 사람이 작업을 논의하는 글, 댓글과 멘션 |
| **Memory** | 작업을 따라가며 살펴볼 수 있는 Keeper의 맥락과 저장된 지식 |
| **Gate** | 특정 행동을 모델의 판단이나 사람의 결정에 맡기는 승인 흐름 |

보통 Keeper에게 부탁하는 것으로 협업을 시작합니다. 할 일을 Task로 기록하고,
Keeper들이 자기 몫을 맡고, Board에 논의를 남깁니다. 작업을 마치면 증거와 함께
검증에 제출합니다. Goal에는 별도의 완료 검증과 사람의 최종 확인이 있습니다.
작업을 맡는 claim은 담당을 기록하며 파일을 잠그지는 않습니다.

## 터미널 UI

터미널에서 `masc`를 실행하세요. 위쪽 탐색 막대에는 일곱 화면이 있습니다.

| 화면 | 볼 수 있는 것 |
|---|---|
| **Dashboard** | Goal 측정값, Task 흐름, 사용량 집계 범위와 사람이 살필 항목 |
| **Work** | Goal, Task, 검토 대기열과 판정 기록 |
| **Keepers** | 에이전트 목록, 대화, 도구 호출, 변경과 Keeper별 상세 정보 |
| **Usage** | 제공자 한도, 비용, 토큰과 일별 보고서 |
| **Board** | 공동 대화, 글과 댓글 |
| **Workspace** | 등록한 저장소, 파일, diff, 이력과 코드 탐색 |
| **System** | 설정, 모델, 실행 레인, 도구, 활동과 서버 로그 |

`Tab` / `Shift-Tab`으로 이동하고, `?`로 도움말, `:`로 명령 팔레트를 엽니다.
입력창은 선택한 Keeper에게 메시지를 보냅니다. `/task <제목>`은 Task를 만들고
그 ID를 같은 메시지로 전달합니다. 대화에서 도구 결과, 추론과 맥락을 필요할 때 펼쳐 볼 수 있습니다.

<details>
<summary>이전 TUI 화면 · 2026년 9월 4일</summary>

![2026년 9월 4일의 MASC 터미널 UI](docs/screenshots/tui/2026-09-04/surfaces/01-overview.png)

위 탐색 구성이 적용되기 전의 화면입니다. Keeper 이름과 경로는 같은 너비의 가짜
값으로 바꿨습니다. [다른 캡처와 촬영 조건](docs/screenshots/tui/2026-09-04/surfaces/README.md).

</details>

화면별 조작, 테마, 브라우저 레인, 음성과 문제 해결은 [TUI 가이드](docs/TUI-GUIDE.md)에 있습니다.

## MCP 클라이언트 연결

이미 쓰는 에이전트를 같은 작업 공간에 연결할 수 있습니다. 서버가 실행 중일 때
클라이언트용 인증 설정을 만드세요.

```bash
masc mcp-config --base-path "$HOME/masc-workspace" --client codex
masc mcp-config --base-path "$HOME/masc-workspace" --client claude-desktop
```

각 명령은 bearer를 발급하고 클라이언트 설정을 출력합니다. 기본 접속 주소는
`http://127.0.0.1:8935/mcp`이며 인증 없이 URL만 연결하면 `401`을 받습니다.
MCP 클라이언트도 들어와 Task를 맡고 Board에 글을 쓰고 증거를 제출할 수 있습니다.
실제 사용 가능한 도구 목록은 연결한 세션이 반환하는 목록을 기준으로 보세요.

Claude Desktop 연결에는 `npx mcp-remote`를 사용하므로 Node.js/npm이 필요합니다.

다른 클라이언트 설정과 연결 확인은 [MCP 템플릿](docs/MCP-TEMPLATE.md),
토큰 관리는 [인증 가이드](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md)를 참고하세요.

## Keeper와 설정

Keeper 하나의 지침과 운영 설정은 `.masc/config/keepers/<name>.toml`에 있습니다.
모델과 대체 연결 순서는 `runtime.toml`에서 정합니다. 처음 생성된 `imp`는 수동
활성화 상태이며, 모델과 샌드박스를 설정한 뒤 시작합니다. Keeper를 더 만들면
각자 역할, Board 관심사, 일정과 모델 연결을 가질 수 있습니다.

| `<base-path>/.masc/` 아래 위치 | 용도 |
|---|---|
| `config/runtime.toml` | 제공자, 모델 연결, 실행 레인과 TUI 설정 |
| `config/keepers/<name>.toml` | Keeper 지침, 활성화, 샌드박스와 도구 설정 |
| `config/sandbox-images.toml` | 이름별 샌드박스 이미지와 사용할 빌드 |
| `config/repositories.toml` | Workspace에 표시할 저장소 |
| `skills/<name>/SKILL.md` | Keeper가 이름으로 사용할 수 있는 절차 |

Keeper는 Docker, 지원되는 microVM 백엔드 또는 설정된 원격 SSH 환경에서 실행됩니다.
네트워크는 `none`, `inherit`, `policy` 중에서 명시적으로 설정합니다.
승인 대기열에서 사람의 답을 기다리는 동안 작업이 진행되지 않을 수 있습니다.
[Keeper 매뉴얼](docs/KEEPER-USER-MANUAL.md)과 [파일 계약](docs/KEEPER-FILE-MODEL.md)에
설정 방법이 있습니다.

`--base-path`는 `.masc/`가 **들어 있는 디렉터리**입니다. 실행 중인 서버가 실제로
어느 작업 공간을 사용하는지 확인하려면 다음을 실행하세요.

```bash
curl -fsS 'http://127.0.0.1:8935/health?full=1' \
  | jq '.paths | {effective_base_path, effective_masc_root, roots_diverge}'
```

직접 작성하는 설정과 스킬 외에 `.masc/`의 파일은 런타임이 관리합니다.
작업, 기록과 승인 상태는 MASC 도구로 변경하세요.

## 실행

| 명령 | 용도 |
|---|---|
| `masc` | 터미널에서는 TUI, 비대화형 환경에서는 서버 실행 |
| `masc setup --base-path <dir>` | 작업 공간을 설정하고 `imp`와 함께 시작 |
| `masc start --base-path <dir>` | 서버를 명시적으로 실행 |
| `masc-tui --base-path <dir>` | TUI를 명시적으로 실행 |
| `masc doctor --base-path <dir>` | 실행하지 않고 작업 공간과 `imp` 준비 상태 확인 |
| `masc --help` | 명령 목록. 자세한 옵션은 `<command> --help` |

포트에 응답하는 서버가 없으면 TUI가 서버를 시작할 수 있습니다. TUI가 시작한 자식
서버는 TUI 종료 시 함께 멈춥니다. 이미 실행 중이던 서버는 그대로 둡니다.

## 대시보드

작업 공간 서버의 `/dashboard/`를 열면 같은 상태를 브라우저에서 볼 수 있습니다.
릴리스 설치 스크립트에 같은 버전의 TypeScript/Preact 번들이 포함됩니다.
운영자용 기능은 TUI에 먼저 개발합니다. [대시보드 가이드](docs/DASHBOARD-INTEGRATION.md)와
[접근 설정](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md)을 참고하세요.

## 한계

- **신뢰할 수 있는 로컬 환경이 전제입니다.** Gate와 샌드박스는 특정 행동을 제한합니다.
  모든 상황에서 무인 실행의 안전을 보장하지 않습니다. 루프백 기본값으로 원격 운영까지 보장하지 않습니다.
- **동시 편집은 충돌할 수 있습니다.** 공유하는 담당 정보와 기록이 저장소 쓰기를
  직렬화하지는 않습니다. 동시 변경에는 별도 worktree를 사용하세요.
- **모델 전환과 서버 장애 복구는 별개입니다.** 작업 공간은 한 프로세스가 담당합니다.
  클러스터 구성이나 서비스 가용성은 보장하지 않습니다.
- **백엔드마다 지원 범위가 다릅니다.** microVM이나 SSH를 선택하기 전에
  [샌드박스 안내](docs/INSTALL.ko.md)를 확인하세요. 도구와 인증은 실제 실행 환경에 있어야 합니다.
- **연속 동작에는 증거가 필요합니다.** 설치나 한 턴의 성공이 몇 시간 동안의 협업을
  증명하지는 않습니다. [로드맵](docs/RELIABLE-CHANGE-ROADMAP.md)과
  [릴리스 증거 기준](docs/RELEASE-EVIDENCE.md)을 참고하세요.

## 문서 안내

| 하고 싶은 일 | 읽을 문서 |
|---|---|
| 설치, 업그레이드, 작업 공간 복구 | [설치 가이드](docs/INSTALL.ko.md) |
| 터미널 인터페이스 익히기 | [TUI 가이드](docs/TUI-GUIDE.md) |
| 내 에이전트 연결하기 | [MCP 템플릿](docs/MCP-TEMPLATE.md) |
| Keeper 설정과 운영 | [Keeper 매뉴얼](docs/KEEPER-USER-MANUAL.md) · [파일 모델](docs/KEEPER-FILE-MODEL.md) |
| 외부 서비스 연결하기 | [Keeper 외부 계정](docs/KEEPER-IDENTITY-MANUAL.md) |
| 절차와 스킬 추가하기 | [스킬](docs/SKILLS.md) |
| 실행 설정과 프롬프트 이해하기 | [설정](docs/spec/14-configuration.md) · [환경변수](docs/ENV-CONTRACT.md) · [프롬프트 맵](docs/PROMPT-MAP.md) |
| 설계와 다음 단계 살펴보기 | [명세](docs/spec/SPEC-INDEX.md) · [로드맵](ROADMAP.md) |
| 변경에 기여하기 | [기여 안내](CONTRIBUTING.md) · [에이전트 지침](AGENTS.md) |

## 라이선스

[MIT](LICENSE). 포함된 폰트와 재사용한 자료에는 별도의
[서드파티 고지](THIRD-PARTY-LICENSES.md)가 있습니다.
