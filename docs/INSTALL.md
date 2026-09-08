# Install, use and upgrade MASC

이 문서는 **0.34.0 릴리스 후보**의 설치 계약입니다. 현재 공개 버전은
[GitHub Releases](https://github.com/jeong-sik/masc/releases/latest)에서 확인합니다.
태그가 게시되기 전에는 아래 `v0.34.0` 다운로드가 동작하지 않습니다.

## 플랫폼과 준비물

| OS / CPU | 릴리스 자산 suffix | 검증 환경 |
|---|---|---|
| Linux x86-64 | `linux-x64` | Ubuntu 24.04 runner + 새 Ubuntu 24.04 container |
| Linux ARM64 | `linux-arm64` | Ubuntu 24.04 ARM runner + 새 Ubuntu 24.04 container |
| macOS Apple Silicon | `macos-arm64` | macOS 14 ARM runner |
| macOS Intel | `macos-x64` | macOS 15 Intel runner |

이 표는 CI 대상입니다. 성공한 해당 릴리스의 `Release` 실행과 실제 자산을
확인해야 설치 검증이 완료된 것입니다. Alpine/musl, 구형 glibc Linux, 위보다
오래된 macOS는 이 바이너리의 검증 대상이 아닙니다. Intel Mac은 Apple
Container 기반 microVM을 제공하지 않으므로 Docker 또는 remote SSH를 선택합니다.
Runner 이름은 [GitHub 공식 목록](https://github.com/actions/runner-images)을 따릅니다.

설치 스크립트는 Bash, curl, Python 3, `sha256sum` 또는 `shasum`을 사용합니다.
OCaml/opam/Dune, Node.js/pnpm은 **바이너리 설치에 필요하지 않습니다**.
공유 라이브러리는 OS에 설치되어 있어야 합니다.

Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl python3 libffi8 libgmp10 libpq5 \
  libssl3t64 libzstd1 zlib1g libncurses6 libtinfo6
```

macOS ([Homebrew 설치 조건](https://docs.brew.sh/Installation)):

```bash
brew install python gmp libpq openssl@3 zstd
```

개선된 macOS 설치기는 다운로드 전에 OS 버전과 Homebrew 런타임 의존성을
확인하고, 없는 패키지만 설치합니다. Homebrew가 없는 터미널에서는 공식
Homebrew 설치 프로그램으로 이어지며, 그 프로그램의 확인·암호 입력을 거칩니다.
비대화형 실행에서는 Homebrew를 미리 준비해야 합니다. `--dry-run`은 패키지를
설치하지 않습니다. Linux 시스템 패키지는 위 명령으로 준비합니다.

macOS의 Homebrew 라이브러리 경로는 해당 CPU의 기본 prefix를 사용합니다.
Apple Silicon의 Intel Homebrew 등 다른 prefix로 연결된 환경은 다운로드 전에
원인을 안내합니다. 패키지 설치 후에도 바이너리가 시작되지 않으면 설치기가
실행 파일의 stderr 원문을 바로 표시합니다.

### macOS에서 `SIGABRT` 또는 `build-commit` 실패

`SIGABRT`는 프로세스의 종료 신호이며, 그 자체로 원인을 알려주지 않습니다.
`dyld: Library not loaded` 같은 stderr 원문과 실패한 실행 파일 경로를 확인하세요.
종료 신호만으로 누락 라이브러리라고 단정하지 않습니다.

0.34.0 배포 파일의 Mach-O 최소 OS는 Apple Silicon **macOS 14.0**,
Intel **macOS 15.0**입니다. 해당 CPU의 기본 Homebrew prefix
(Apple Silicon `/opt/homebrew`, Intel `/usr/local`)에 의존성을 준비합니다.

```bash
brew install python gmp libpq openssl@3 zstd
sw_vers -productVersion
uname -m
```

`otool -L <실패한-실행파일>`로 실제 연결 라이브러리 경로를 확인할 수 있습니다.
의존성과 OS 조건을 맞춘 뒤에도 중단되면 종료 신호와 stderr 원문을 함께 보고하세요.
`--force`는 재다운로드 옵션이며 loader나 OS 호환성 문제를 해결하지 않습니다.

## 설치

```bash
TAG=v0.34.0
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-workspace"
export PATH="$HOME/.local/bin:$PATH"
```

`--prefix` 기본값은 `$HOME/.local/bin`입니다. 터미널의 첫 설치에서는
`.masc`를 담을 workspace 경로를 묻습니다. 새 workspace에는 `$HOME`을
제안하므로 그대로 선택하면 데이터는 그 workspace 아래 `.masc`에 생깁니다. 현재 디렉터리에
기존 `.masc/config`가 있으면 그 workspace를 제안합니다. 명시한 `--base-path`는
질문 없이 사용하며, 비대화형 또는 `--no-wizard`에서는 현재 디렉터리를 유지합니다. `.masc`는 지정한 base path 아래에 생깁니다. 설치 위치와
작업 데이터 위치는 독립적입니다. 릴리스 페이지의 `install.sh`는 해당 버전의 자산을 설치하며, 설치기 수정은
릴리스 노트에 소스 커밋과 함께 기록합니다. 바이너리 태그는 바꾸지 않습니다.
체크섬이 없거나 불일치하면 설치를 중단합니다.

`--no-wizard`는 모델 선택을 건너뜁니다. `--provider <id>`는
`runtime.toml`의 공급자 catalog에서 선택합니다. 마법사는 사용 가능한 모델 서버와
CLI 인증 상태를 탐지하고 `[runtime].default`를 선택하며 API 키는 저장하지 않습니다.
모델이 없어도 서버 설치와 상태 화면 사용은 가능합니다.

## 첫 설치 마법사

마법사 메뉴에는 공급자 이름, 현재 탐지 상태, `--provider`에 쓸 ID가 함께
나옵니다. 숫자로 선택하거나 Enter로 표시된 기본값을 선택합니다. 잘못된
숫자는 다시 입력하고, 입력이 닫히면 선택을 취소합니다.

| 실행 상황 | 동작 |
|---|---|
| 터미널에서 첫 설치 | 공급자 메뉴를 표시하고 선택을 저장 |
| 입력 파이프/자동화, 사용 가능한 출처가 하나 | 해당 출처를 선택 |
| 입력 파이프/자동화, 사용 가능한 출처가 없거나 여러 개 | 자동 모드는 선택을 보류; `--wizard`를 강제했다면 `--provider` 요구 |
| `--provider <id>` | 기존 작업 공간에서도 해당 공급자를 선택 |
| `--no-wizard` | 모델 선택과 연결 검사를 생략; `--provider`와 함께 사용할 수 없음 |
| 기존 설정이 있는 일반 업그레이드 | 기존 선택 보존; 다시 선택하려면 `--wizard` |

설치한 태그의 스크립트로 다시 선택할 수 있습니다. 새 API 키는 서버가 시작되는
shell에서 export하고, 이미 실행 중인 서버에는 자동 반영되지 않는다는 점을 확인합니다.

```bash
bash /tmp/masc-install.sh --version "$TAG" \
  --base-path "$HOME/masc-workspace" --wizard
```

공급자 탐지에서 `cloud`는 API 키의 유효성이나 모델 응답을 증명하지 않습니다.
CLI는 자체 로그인 probe로 확인하며 probe 미지원은 별도로 표시합니다.
HTTP 방식은 catalog에 선언된 healthcheck를
호출합니다. credential 또는 healthcheck가 없으면 검사를 건너뛰었다고 표시합니다.
연결 검사 통과도 실제 모델 생성·도구 실행·Keeper 연속 실행의 증거는 아닙니다.
자동화에서 `MASC_INSTALL_NO_PING=1`은 설치 후 연결 검사만 생략하며, 마법사의
로컬 서버 탐지는 실행합니다. 모든 마법사 탐지를 생략하려면 `--no-wizard`를 씁니다.
`--sandbox`는 `--team`과 함께 사용하며 기존 Keeper 설정을 일괄 변경하지 않습니다.

## 기본 설치 내용

| 위치 | 내용 / 용도 |
|---|---|
| `<prefix>/masc` | HTTP/MCP 서버, 설정·로그인·Keeper 관리 CLI. 터미널에서 실행하면 TUI 진입 |
| `<prefix>/masc-tui` | Keeper, 채팅, 작업, 보드, 승인, 로그를 보는 터미널 UI |
| `<prefix>/masc-browser-host` | Firefox 계열 native messaging 연결 실행 파일. 설치만으로 브라우저 등록되지는 않음 |
| `<prefix>/masc-deployment-preflight-helper` | 실행 환경 사전점검 보조 바이너리 |
| `<prefix>/masc-check-runtime-deployment-preflight` | 사전점검 실행 스크립트 |
| `<prefix>/.masc-releases/<receipt-hash>/` | 서버와 같은 커밋의 대시보드, 서버 실행 파일, 검증 receipt |
| `<base-path>/.masc/config/` | 내장 runtime/model overlay 및 기본 설정 seed. 운영 중 도구·프롬프트도 내장 자산에서 관리 |
| `<base-path>/.masc/microvm/shim/` | Linux guest용 exec shim과 SHA256 sidecar. `--no-guest-shim`으로 생략 가능 |

공개된 **0.34.0 바이너리**는 기본 Keeper를 만들지 않고 `browser-lanes` skill을 설치합니다.
동결 이후의 `main` 소스 빌드는 autoboot이 꺼진 `imp` 하나를 seed합니다.
릴리스 설치기는 설정을 바이너리에서 가져오므로, 설치기만 갱신해도 0.34.0의 명단은
바뀌지 않습니다. 지침은 시작점이라 그대로 고쳐 쓰면 됩니다. 모델 가중치, 모델 CLI, API 키, Docker,
Apple Container, SSH 서버, 브라우저/확장, Slack/Discord 계정, 자동 시작 서비스는
설치하지 않습니다. 사용 가능한 실행 환경 탐지는 설치나 인증을 대신하지 않습니다.

## 처음 실행하고 할 수 있는 일

```bash
masc --base-path "$HOME/masc-workspace"
```

터미널에서 TUI가 열리고 해당 포트에 서버가 없으면 시작합니다. HTTP 서버만
실행하려면 다음 명령을 사용합니다.

```bash
masc start --base-path "$HOME/masc-workspace"
```

서버는 foreground로 실행됩니다. 별도 터미널에서 상태를 확인합니다.

```bash
curl http://127.0.0.1:8935/health
curl 'http://127.0.0.1:8935/health?full=1'
```

`/health` 응답은 HTTP listener가 열렸다는 뜻입니다. 첫 Keeper를 만들기 전에는
full health의 `startup.state_ready`가 `true`인지도 확인합니다. 부팅 초기에는
listener가 먼저 응답하고 내부 상태 초기화는 진행 중일 수 있습니다.

브라우저에서 `http://127.0.0.1:8935/dashboard/`를 엽니다. 대시보드는 설치된
번들을 자동 선택하므로 소스 디렉터리에서 시작할 필요가 없습니다.
[인증 안내](LOCAL-DASHBOARD-AUTH-RUNBOOK.md)에 따라 쓰기 권한을 설정합니다.

MCP 클라이언트는 `http://127.0.0.1:8935/mcp`에 bearer와 함께 연결합니다.
설치 스크립트가 출력하는 `masc login ... --shell` 명령과
[클라이언트 설정](../README.md#mcp-client-setup)을 사용하세요.
외부 에이전트는 작업을 등록·claim하고 목표, 보드, 댓글, 실행 증거를 공유할 수 있습니다.
이 경우 MASC 자체의 모델 연결 없이도 외부 에이전트가 자기 모델을 사용합니다.

Keeper를 실행하려면 모델 출처와 도구 실행 환경을 모두 준비합니다.

1. `runtime.toml`에서 모델을 선택합니다. API 방식은 서버를 시작하는 shell에
   해당 credential 환경변수를 export합니다. CLI 방식은 그 CLI를 별도 설치하고 로그인합니다.
2. Docker 방식은 Docker daemon을 시작하고 `masc sandbox-image`로 기본 실행 이미지를
   준비합니다. microVM/remote SSH는 각 backend 설정이 필요합니다.
3. TUI Keepers 화면 또는 `masc keeper-create --help`로 Keeper를 생성합니다.
   미리 구성된 팀이 필요하면 설치 시 `--team classic --sandbox docker`를 사용합니다.
   팀 파일은 다음 서버 시작 시 Keeper를 자동 부팅하므로 모델·sandbox를 먼저 준비합니다.

서버가 실행 중이고 Docker 이미지와 모델을 준비했다면, 별도 터미널에서 첫 Keeper를
명시적으로 만들 수 있습니다. `login`과 `keeper-create`는 같은 base path, agent,
host/port를 사용합니다.

```bash
masc login --base-path "$HOME/masc-workspace" --host 127.0.0.1 --port 8935 \
  --agent local-admin --role admin --no-expiry --json
masc keeper-create --base-path "$HOME/masc-workspace" --host 127.0.0.1 --port 8935 \
  --agent local-admin --name scout --sandbox-profile docker --network-mode none \
  --no-skills --no-autoboot --no-proactive \
  --instructions '주어진 작업을 수행하고 실제 도구 결과를 근거로 보고한다.'
```

생성 요청은 Keeper를 즉시 부팅합니다. `--no-autoboot`는 이후 서버 재시작 때의
자동 부팅을 끄며, `--no-proactive`는 자발적 활동을 끕니다. TUI나 대시보드에서
`scout`에게 작업을 보내세요. 이 예제의 `none`은 guest 외부 네트워크를 막으므로
웹·Git 원격 작업에는 `inherit` 등 작업에 맞는 네트워크 설정이 필요합니다.
같은 이름으로 다시 실행하면 기존 Keeper를 재설정합니다.

첫 도구 실행이 대기하면 채팅의 pending tool approval을 확인하고 승인에 응답하세요.
Keeper 채팅의 도구 승인(Auto/Yolo 및 도구별 승인)은 workspace Gate의
`auto_judge`/`manual`과 외부 서비스 승인 경로와 별개입니다. per-Keeper Gate를
`always_allow`로 바꿔도 workspace의 `auto_judge`를 완화할 수 없습니다.
승인 대기를 모델 연결이나 설치 실패로 오해하지 않도록 각 승인 상태를 확인하세요.

Keeper는 설정된 모델로 턴을 수행하고, sandbox에서 도구를 실행하며, 작업·보드·채팅을
통해 협업합니다. 일정 실행, 승인 판단, 외부 connector와 브라우저 조작은 해당
runtime/credential/backend 설정이 있어야 합니다. 브라우저는 별도
[native host 연결 안내](../connectors/browser/host/README.md)를 따릅니다.
서버 설치 smoke는 모델 응답이나 장시간 Keeper 연속 실행을 증명하지 않습니다.

## 이미지와 Linux/microVM의 경계

설치 스크립트는 sandbox 이미지를 다운로드하거나 빌드하지 않습니다.
`masc sandbox-image`는 일반 이미지의 **recipe**를 내장하고 있으며 첫 빌드에는
Debian base image와 패키지를 받는 네트워크가 필요합니다.

| 실행 환경 | 준비 | 검증 범위 |
|---|---|---|
| Linux + Docker | Docker daemon을 별도 설치·시작하고 `masc sandbox-image` 실행 | 서버 설치와 이미지 생성/도구 실행은 별도 검사 |
| Apple Silicon + Apple Container | macOS 26 및 `container` 설치, 아래 runtime 지정 빌드 | macOS 14 서버 CI 통과만으로 이 backend를 증명하지 않음 |
| Linux + nerdctl/Kata | containerd/nerdctl/Kata와 가상화 지원, backend 명시, 해당 store에 이미지 생성 | 작업 볼륨을 멱등 생성·inspect 확인; 실제 Kata 검증 필요, policy networking 미지원 |
| remote SSH | 원격 endpoint와 인증·shim·도구 준비 | 로컬 Docker/microVM 이미지와 독립적인 원격 환경 |

```bash
# Docker Keeper의 이미지 저장소
masc sandbox-image

# Apple Container Keeper의 별도 이미지 저장소
masc sandbox-image --runtime apple_container

# nerdctl/Kata Keeper의 별도 이미지 저장소
masc sandbox-image --runtime nerdctl_kata
```

Linux에서 실행 중인 서버와 같은 base path를 지정하여 Keeper를 생성합니다.
먼저 위 Kata runtime·이미지와 서버의 모델 설정을 준비하고 admin credential로
로그인해야 합니다. CLI가 선택한 backend를 서버에 전달하고 Keeper TOML에 저장합니다.

```bash
masc keeper-create --base-path "$HOME/masc-workspace" \
  --agent local-admin --name linux-worker \
  --sandbox-profile microvm --microvm-backend nerdctl_kata \
  --network-mode none --no-autoboot --no-proactive \
  --instructions "지정된 작업을 수행하고 실행 결과와 증거를 보고한다."
```

`--microvm-backend`는 `microvm`에만 유효합니다. 생략하면 기존 backend를
유지하며, 새 Linux Keeper에는 host 기본값이 없으므로 명시해야 합니다.
`--edit`와 함께 지정하면 다른 선언 flag와 동일하게 충돌로 거부합니다.

`--runtime`만 바꿔도 hypervisor나 daemon을 설치하지는 않습니다.
`--runtime nerdctl_kata`로 직접 빌드하려면
[nerdctl의 BuildKit 설정](https://github.com/containerd/nerdctl/blob/main/docs/build.md)도
필요합니다. containerd와 Kata만 실행 중인 상태로는 이미지 빌드 준비가 끝난 것이 아닙니다.
Docker store에 있는 이미지는 Apple Container/nerdctl store에 자동 복사되지 않습니다.
Linux nerdctl/Kata는 해당 runtime의 영속 named volume을 생성하고 inspect로
이름과 mountpoint를 확인합니다. guest를 다시 만들어도 같은 볼륨을 연결합니다.
이 저장소는 호스트의 관리 디렉터리이며 Apple의 guest ext4 디스크와 다릅니다.
`MASC_KEEPER_MICROVM_WORK_VOLUME_SIZE`는 nerdctl에서 강제되지 않고 실제 사용 가능한
공간은 호스트 filesystem을 따릅니다. 이 차이는 부팅 로그에 표시합니다.
Apple에서 측정한 host descriptor 특성이 Linux에서도 같다고 보장하지 않습니다.
`network_mode=none` 또는 `inherit`를 사용하며 Linux의 `policy`는 지원하지 않습니다.
`scripts/smoke-nerdctl-kata-volume.sh`는 Kata의 볼륨·격리를 검사합니다.
설치된 Keeper까지 검증하려면 `Kata volume smoke` workflow의 `release_run`에
Linux x64 작업이 성공한 Release 실행 번호를 지정합니다. 이 경로는 해당 바이너리와
shim을 설치하고 이미지 생성·Keeper 도구 실행·정본 checkpoint·게스트 재생성 후
파일 보존을 확인합니다. 단순 볼륨 검사 통과만으로 설치된 Keeper 실행을 보장하지 않습니다.
[Apple Container](https://github.com/apple/container#requirements)는 Apple Silicon과
macOS 26을 지원하며, [Kata](https://github.com/kata-containers/kata-containers/blob/main/docs/installation.md)는
호스트 가상화 조건을 확인해야 합니다. Microsandbox의 현재 MASC 연결은 필수 격리
조건에 제약이 있어 검증된 대안으로 안내하지 않습니다.

`masc-sandbox:general`에는 bash, CA certificates, curl, findutils, gh, git,
less, procps, Python 3, ripgrep이 들어갑니다. **Node, pnpm, OCaml, 컴파일러,
SSH client, 모델 CLI는 포함하지 않습니다.** 프로젝트 빌드·테스트가 목적이면
필요한 toolchain이 있는 이미지를 준비하고 Keeper의 `sandbox_image`로 지정합니다.
저장소의 `Dockerfile.keeper-sandbox`는 MASC 개발용 별도 이미지이며 일반 설치물이 아닙니다.

## 초기 프롬프트·skills·Keeper

기본 설치는 **자동 시작하지 않는 Keeper `imp` 1명**과 내장 스킬
`browser-lanes`, `browser-design`, `frontend-implement`, `frontend-verify`,
`evidence-review`를 준비합니다. 모델과 샌드박스를 설정한 뒤 Keeper를 시작하세요.

Task·Goal 검증 에이전트도 workspace에 게시된 instruction Skill을
`keeper_skill`로 읽을 수 있습니다. 기본 `evidence-review`는 계약·실행 로그·리비전을
대조하는 절차를 안내합니다. Skill은 조회 방법을 제공하며 새 도구나 실행 권한을
부여하지 않습니다. 설치된 Skill이 없으면 기존 증거 조회로 검증을 이어갑니다.

프롬프트는 다음 세 곳만 구분하면 됩니다.

| 바꾸려는 내용 | 편집 위치 |
|---|---|
| 모든 Keeper의 작업·검증·글쓰기 방식 | 프롬프트 편집기의 `keeper` |
| 특정 Keeper의 역할 | `.masc/config/keepers/<name>.toml`의 `instructions` |
| 도구별 상세 절차 | 해당 스킬 |

공통 본문은 [한국어](../config/prompts/keeper.md)와
[영어](../config/prompts/keeper.en.md)로 제공합니다. 프롬프트 편집기에서
`keeper`를 열고 **한국어 / English**를 선택하면 초안이 바뀝니다.
내용을 확인한 뒤 **오버라이드 적용**을 누르세요. 저장하지 않은 초안이 있으면
먼저 저장하거나 초기화해야 다른 언어를 고를 수 있습니다.
언어 선택은 공통 행동 지침만 바꿉니다. 상황별 슬롯·도구 스키마는 공용이며,
개별 Keeper의 역할 지침과 답변 언어를 강제로 바꾸지 않습니다.

`config/prompts/keeper.md`의 `###` 아래는 런타임이 필요한 때에 렌더링하는
슬롯입니다. 두 언어 본문을 동시에 보내거나 이 슬롯 전체를 매 턴 넣지 않습니다.
공통 행동 규칙은 본문에 한 번만 쓰고 역할 지침에는 담당 업무만 적으세요.

설치된 `.masc/config/prompts/`는 배포본입니다. 서버가 시작할 때 내장본으로
맞추므로 직접 편집하지 마세요. 편집기에서 저장한 내용은
`.masc/prompt_overrides.json`에 보관되며, 이후 구성하는 프롬프트에 적용됩니다.
업그레이드해도 유효한 override가 있으면 배포본보다 우선하므로, 새 기본 지침을
쓰려면 편집기에서 해당 언어를 다시 선택해 저장하거나 override를 해제하세요.
`keeper.identity` 같은 슬롯 override도 별도 항목입니다.

언어만 바꾸려고 전체 프리셋을 복원할 필요는 없습니다. 프리셋은 여러 Keeper의
역할·프롬프트·모델 배정을 함께 저장하고 되돌릴 때 사용하세요.
`constitution.xml`은 개발 계약이며 Keeper의 시스템 프롬프트가 아닙니다.

`browser-lanes`는 브라우저 연결·탐색·조작·검증 절차를 담습니다.
브라우저나 확장, 인증을 설치하지는 않습니다. 기존 스킬 패키지는 덮어쓰지 않으므로
업그레이드할 때 사용자 변경과 새 안내를 비교해 반영하세요.
`--team classic`을 선택하면 다음 네 Keeper TOML을 추가합니다.

| Keeper | 개별 지침의 역할 |
|---|---|
| `tech_lead` | 요구사항 분해, 역할 분배, diff/증거 검토 |
| `backend` | 백엔드 구현과 검증 |
| `frontend` | 프론트엔드 구현과 검증 |
| `qa` | 요구사항에 대한 테스트·검증 |

이 preset은 `autoboot_enabled=true`, `sandbox_profile="docker"`,
`network_mode="inherit"`를 사용하고 fleet 기본 모델을 따릅니다. 역할 지침은
컴파일러나 인증을 설치하지 않으며 개별 `skills` 패키지도 추가하지 않습니다.

Skill 검색 경로는 `runtime.toml`의 `[[skills.sources]]`가 선언합니다.
기본 순서는 `<base-path>/.masc/skills`, `<base-path>/.agents/skills`,
`<user-home>/.masc/skills`, `<user-home>/.agents/skills`입니다.
설치가 비어 있어도 **이미 존재하는 사용자 skill은 검색될 수 있습니다**.
각 skill은 `<name>/SKILL.md`와 필요한 리소스로 구성하고, Keeper 생성 시
`--skill` 또는 `--no-skills`로 선택을 명시합니다. Codex/Claude에 설치한 모든 skill이
MASC에 자동 복사되는 것은 아닙니다.

## 업그레이드와 복구

릴리스에 첨부된 `install.sh`를 새로 받은 뒤, 기존과 같은 prefix/base path로 실행합니다.

```bash
bash /tmp/masc-install.sh --version "$TAG" \
  --base-path "$HOME/masc-workspace" --force --no-wizard
```

0.34.0부터 `--force`는 바이너리를 갱신하며 기존 runtime 설정, 모델 선택,
Keeper 파일을 보존합니다. runtime과 model overlay가 이미 있는 작업 공간에서는
새 내장 skill만 보충하고, 기존 설정과 사용자가 삭제한 선택 설정 파일을 보존합니다.
새 설치 또는 필수 설정이 없는 작업 공간에서는 기본 설정을 seed합니다. 설정 초기화가 목적일
때만 `--reset-config`를 추가합니다. 이 옵션은 seeded 설정과 선택한 팀 파일을
덮어쓰므로 사용자 설정을 별도 보관한 다음 사용하세요.

서버/대시보드와 prefix의 companion 실행 파일은 설치 실패 시 이전 상태로 복구합니다.
workspace의 guest shim과 명시적으로 초기화한 설정은 이 prefix transaction에
포함되지 않습니다. 프로세스가 강제 종료되어 `.masc-install-transaction`이 남으면
[배포 transaction 안내](design/installed-dashboard-distribution.md)를 확인합니다.

실행 중인 서버는 설치만으로 교체되지 않습니다. 진행 중인 작업을 정리한 뒤 서버를
재시작하고 `masc --version`, `/health?full=1`, 대시보드를 다시 확인합니다.
이전 버전으로 돌아갈 때도 그 태그의 설치 스크립트를 사용합니다. 이전 버전의
`--force`는 설정까지 초기화할 수 있으므로 설정 백업과 `--no-seed --no-wizard`가
필요합니다. 이전 release directory는 실행 중인 프로세스와 복구를 위해 보존됩니다.

## 릴리스 검증

`Release` workflow는 네 native target을 모두 필수로 빌드하고, checksum을
사용하는 `file://` 설치 → config seed → 설치된 서버 health → 대시보드 검증을
수행합니다. Linux는 OCaml 개발 환경이 없는 새 Ubuntu container에서도 같은
설치를 실행합니다. TUI와 browser host의 `--help`로 동적 로더가 동작하는지도 확인합니다.
Linux native runner에서는 설치된 실행 파일로 새 Keeper를 생성하고 로컬 모델
fixture가 요청한 도구를 실제 Docker에서 실행하는 첫 턴 검증도 수행합니다.
ToolResult가 다음 모델 요청으로 돌아오고 host 파일과 durable checkpoint가
일치해야 통과합니다. 모델 품질·실제 API 인증·장시간 연속성은 이 fixture가
증명하지 않습니다. `keeper-create` CLI의 성공·인증 거부 종료도 별도 검사합니다.

`workflow_dispatch`는 브랜치 artifact 검증용이며 공개 릴리스를 생성하지 않습니다.
검증된 커밋에 `v0.34.0` 태그를 push하면 네 빌드와 자산 검증을 거쳐 GitHub Release와
`SHA256SUMS`를 게시합니다. 태그, CI 성공, 실제 release assets, 설치 후 실행 결과는
각각 확인해야 합니다.

## 제거

실행 중인 MASC 서버와 TUI를 종료한 뒤, 릴리스에서 받은 최신 설치기를 사용합니다.
기본 제거는 프로그램과 대시보드만 삭제하며, 설정·Keeper·기록과 Homebrew 의존성은 보존합니다.

```bash
bash /tmp/masc-install.sh --uninstall --dry-run
bash /tmp/masc-install.sh --uninstall
```

설치할 때 `--prefix`를 지정했다면 제거할 때도 같은 값을 지정하세요.
제거는 네트워크, Python, Homebrew 없이 실행되며 prefix 디렉터리나 다른 파일은 지우지 않습니다.
중단된 설치 transaction이 남아 있으면 이를 먼저 복구하라는 오류를 냅니다.

데이터도 제거하려면 **실제 설치했던 workspace 경로**를 명시해야 합니다.
아래 예시는 그 workspace 아래 `.masc`를 삭제합니다. HOME을 workspace로
선택했다면 `--base-path "$HOME"`입니다. `.masc` 디렉터리 자체를 base path로 넣지 마세요.

```bash
bash /tmp/masc-install.sh --uninstall --purge-data \
  --base-path "$HOME/masc-workspace" --dry-run
# 삭제 대상 확인 후 --dry-run 없이 실행
```

다른 경로를 가리키는 `.masc` 또는 배포 디렉터리 symlink는 링크 자체만 삭제합니다.
