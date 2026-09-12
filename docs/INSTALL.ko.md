# Install, use and upgrade MASC

[English](INSTALL.md)

이 문서는 **0.35.5 설치 계약**입니다. 태그와 자산 제공 여부는
[GitHub Releases](https://github.com/jeong-sik/masc/releases)에서 확인하세요.
아래 다운로드 명령은 `v0.35.5`과 같은 버전의 설치기를 선택합니다.

0.35.2 설치기를 사용 중이라면 해당 태그의 문서를 참고하세요. 다중 선택은 0.35.2부터 지원합니다.

## 플랫폼과 준비물

| OS / CPU | 릴리스 자산 suffix | 검증 환경 |
|---|---|---|
| Linux x86-64 | `linux-x64` | Ubuntu 24.04 runner + 새 Ubuntu 24.04 container |
| Linux ARM64 | `linux-arm64` | Ubuntu 24.04 ARM runner + 새 Ubuntu 24.04 container |
| macOS Apple Silicon | `macos-arm64` | macOS 14 ARM runner |
| macOS Intel | `macos-x64` | macOS 15 Intel runner |

이 표는 CI 대상입니다. 성공한 해당 릴리스의 `Release` 실행과 실제 자산을
확인해야 설치 검증이 완료된 것입니다.

Linux 바이너리는 Ubuntu 22.04 컨테이너에서 빌드하므로 **glibc 2.35 이상**이
필요합니다. Ubuntu 22.04, Debian 12, RHEL 10 그리고 그 이후 배포판이 해당합니다.
더 높은 버전을 요구하는 바이너리가 나오면 릴리스가 실패하므로, 이 기준은
의도가 아니라 검사 대상입니다(`scripts/check-glibc-floor.sh`). glibc 기준과
아래 공유 라이브러리 목록은 별개이며, 라이브러리는 배포판마다 따로 갖춰야
합니다. RHEL 9는 glibc 2.34라서 이 기준에 못 미칩니다. Alpine을 비롯한 musl
배포판과 위보다 오래된 macOS는 검증 대상이 아닙니다. Intel Mac은 Apple
Container 기반 microVM을 제공하지 않으므로 Docker 또는 remote SSH를 선택합니다.
Runner 이름은 [GitHub 공식 목록](https://github.com/actions/runner-images)을 따릅니다.

설치 스크립트는 Bash, curl, tar, `sha256sum` 또는 `shasum`을 사용합니다.
macOS는 Python과 실행 라이브러리를 함께 제공하므로 Homebrew나 별도 Python 설치가
필요하지 않습니다. Linux x64와 ARM64도 검증된 Python을 함께 제공합니다.
아래 시스템 라이브러리는 여전히 필요합니다.
OCaml/opam/Dune, Node.js/pnpm은 **바이너리 설치에 필요하지 않습니다**.

Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl libffi8 libgmp10 libpq5 \
  libssl3t64 libzstd1 zlib1g libncurses6 libtinfo6
```

Ubuntu 22.04와 Debian 12는 OpenSSL 패키지 이름이 `libssl3t64`가 아니라 `libssl3`입니다.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl libffi8 libgmp10 libpq5 \
  libssl3 libzstd1 zlib1g libncurses6 libtinfo6
```

macOS는 **Apple Silicon에서 macOS 14.0 이상**, **Intel에서 macOS 15.0 이상**이 필요합니다. 설치기가 해당 CPU의 Python과 실행 라이브러리를 검증해 릴리스 파일과 함께 설치합니다. Homebrew나 Xcode 명령줄 도구를 설치하지 않습니다.

기본 sandbox에는 실행 중인 Docker 엔진이 필요하며, 모델 연결에는 해당 CLI 로그인이나 API 인증이 필요합니다. `masc setup` 전에 준비해 주세요.

시작에 실패하면 설치기가 표시하는 실행 파일 경로와 stderr 원문을 확인하세요. `SIGABRT` 같은 종료 신호만으로 누락 라이브러리라고 단정할 수는 없습니다. `--force`는 workspace 설정을 보존하면서 릴리스 파일을 다시 설치하며, 지원하지 않는 OS를 호환되게 만들지는 않습니다.

## 설치

```bash
TAG=v0.35.14
curl -fsSL "https://github.com/jeong-sik/masc/releases/download/${TAG}/install.sh" \
  -o /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-workspace"
```

설치가 끝나면 아래 명령을 따로 실행해 현재 터미널의 PATH를 설정하세요.

```bash
export PATH="$HOME/.local/bin:$PATH"
```

선택 사항: 실행 전에 스크립트를 읽으려면 `less /tmp/masc-install.sh`를 실행하세요. `q`를 눌러 나간 다음 위의 `bash` 설치 명령을 실행합니다.

재설치할 때 `--force`나 `--wizard`는 `bash /tmp/masc-install.sh` 명령 끝에 붙입니다. `export PATH=...`에는 설치 옵션을 붙이지 마세요.

`--prefix` 기본값은 `$HOME/.local/bin`입니다. 터미널의 첫 설치에서는
`.masc`를 담을 workspace 경로를 묻습니다. 새 workspace에는 `$HOME`을
제안하므로 그대로 선택하면 데이터는 그 workspace 아래 `.masc`에 생깁니다. 현재 디렉터리에
기존 `.masc/config`가 있으면 그 workspace를 제안합니다. 명시한 `--base-path`는
질문 없이 사용하며, 비대화형 또는 `--no-wizard`에서는 현재 디렉터리를 유지합니다. `.masc`는 지정한 base path 아래에 생깁니다. 설치 위치와
작업 데이터 위치는 독립적입니다. 릴리스 페이지의 `install.sh`는 해당 버전의 자산을 설치하며, 설치기 수정은
릴리스 노트에 소스 커밋과 함께 기록합니다. 바이너리 태그는 바꾸지 않습니다.
체크섬이 없거나 불일치하면 설치를 중단합니다.

`--no-wizard`는 모델 선택을 건너뜁니다. 자동화에서는 `--provider <id>`로
기존 공급자를 선택합니다. 대화형 마법사는 여러 연결과 모델을 함께 고른 뒤 imp의
기본 연결과 대체 순서를 선택합니다. API 키 값은 저장하지 않고 환경변수 이름만 사용합니다.

## 첫 설치 마법사

**↑/↓로 이동하고 Space로 여러 항목을 선택한 뒤 Enter로 진행**합니다.
하나를 고르는 화면에서는 Enter로 선택합니다. `q`로 돌아가거나 취소할 수 있습니다.
커서 조작을 지원하지 않는 터미널은 번호를 표시하며, `1,3`처럼 여러 번호를 입력합니다.

모델 목록은 CLI 캐시, HTTP 서버, 기존 연결, 설치된 catalog에서 읽습니다.
목록에 있는 모델도 저장 전에 실제 응답과 무해한 도구 호출을 통과해야 합니다.
실패하면 재시도, 해당 연결 제외, 다시 선택, 나중에 설정 중에서 고릅니다.
모델을 추가해도 기존 연결은 그대로 남습니다.

| 실행 상황 | 동작 |
|---|---|
| 터미널에서 첫 설치 | 여러 연결·모델 선택 후 실제 응답·도구 검사 |
| 입력 파이프/자동화, 출처가 하나 | 해당 출처 선택; 연결 probe 결과 별도 표시 |
| 입력 파이프/자동화, 출처가 없거나 여러 개 | 선택 보류; 강제 `--wizard`는 `--provider` 필요 |
| `--provider <id>` | 기존 workspace에서도 지정 공급자 선택 |
| `--no-wizard` | 모델 선택 생략; `--provider`와 함께 사용 불가 |
| 기존 설정이 있는 일반 업그레이드 | 선택 보존; 다시 고르려면 `--wizard` |

```bash
bash /tmp/masc-install.sh --version "$TAG" \
  --base-path "$HOME/masc-workspace" --wizard
```

`masc setup`은 imp를 준비하기 전에 선택한 모델을 다시 검사합니다.
모델·도구 검사 통과와 Docker·Keeper sandbox 준비는 별도 단계로 표시합니다.
자동화의 `MASC_INSTALL_NO_PING=1`은 공급자 연결 probe만 생략하며 모델 응답을
검증한 것으로 처리하지 않습니다. `--sandbox`는 `--team`과 함께 사용하며
기존 Keeper 설정을 일괄 변경하지 않습니다.

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

**0.35.5 바이너리**는 `activation_mode = "manual"`인 `imp` 하나와 `browser-lanes` skill을 설치합니다.
`imp`의 기본 sandbox는 Docker이며, 모델과 실행 환경을 준비한 뒤 직접 시작합니다.
설치기는 설정을 바이너리에서 가져옵니다. 지침은 시작점이라 그대로 고쳐 쓰면 됩니다. 모델 가중치, 모델 CLI, API 키, Docker,
Apple Container, SSH 서버, 브라우저/확장, Slack/Discord 계정, 자동 시작 서비스는
설치하지 않습니다. 사용 가능한 실행 환경 탐지는 설치나 인증을 대신하지 않습니다.

## 모델 연결 선택

Codex 캐시가 없는 첫 설치에서는 설치된 CLI의 내장 모델 목록에서 context 한도를
읽습니다. 인증이나 모델 호출은 하지 않으며, API catalog의 최대값을 Codex 한도로
사용하지 않습니다. 실제 모델 사용 가능 여부는 저장 전 응답·도구 검사로 확인합니다.

기존 API 공급자, Claude Code, Codex, 로컬 Ollama 모델을 목록에서 선택합니다.
**Add another server URL**에서는 llama.cpp, vLLM, OpenAI-compatible 서버나
다른 컴퓨터의 Ollama를 연결할 수 있습니다. 기존 Antigravity 연결도 표시되지만
실제 검증 어댑터가 없는 런타임은 대화형 준비 검사를 통과할 수 없습니다.

컨텍스트 크기는 모델 메타데이터나 동일한 연결의 기존 설정에서 읽습니다.
Ollama는 선택한 모델만 필요에 따라 로드하고 실제 설정·실행 중인 컨텍스트를
사용합니다. 모델 구조상 최대치를 그대로 할당하지 않습니다. 단일 모델 llama.cpp는
`/props`의 서버 설정값을 읽습니다. 한도를 알 수 없을 때만 다시 선택하거나
문서에 명시된 서버 한도를 고급 입력으로 지정합니다. 도구 지원 여부 퀴즈는 없습니다.

여러 모델을 함께 등록하고 기본 모델과 대체 순서를 고릅니다. 이 순서는 대화 레인에
적용되며 내부 보조 판단 레인은 기본 모델을 사용합니다. 다른 Keeper의 명시적
연결 지정은 유지합니다. 같은 연결을 다시 고르면 재사용하고 모델·연결 설정이
달라지면 별도 연결로 보존합니다.

같은 바이너리가 임시 설정을 검증하고 선택한 모델 모두의 응답·도구 호출을
확인한 후 반영합니다. 검증 실패 시 기존 파일은 보존됩니다. 인증값은 shell이나
CLI 인증 저장소에 남으며, 마법사는 CLI·모델 가중치·Docker를 설치하거나 로그인하지
않습니다. **Configure later**로 미룰 수 있고 imp는 자동으로 시작하지 않습니다.

## `imp`와 첫 대화 (0.35.5)

이 경로는 **0.35.5 설치 계약**입니다. 다운로드 전에
[GitHub Releases](https://github.com/jeong-sik/masc/releases)에서 태그와 자산 제공 여부를 확인하세요.

`masc`를 실행하세요. `MASC_BASE_PATH` export는 필요 없습니다. 저장된 작업 공간이
없으면 제안되는 `~/MASC` 디렉터리를 Enter로 선택하거나 다른 위치를 고르세요.
디렉터리는 선택한 뒤에 만들어집니다. 명시적인 `--base-path`와 기존 환경 설정은
저장된 기본값보다 우선합니다.

이어지는 setup 여정에서 모델 연결과 샌드박스를 선택합니다. 모델을 여러 개 고르고
대체 순서를 정할 수 있습니다. Claude Code·Codex는 연결 검사가 실패하면 공식
로그인을 열고 같은 선택으로 다시 시도할 수 있습니다. 선택한 모델은 저장 전에
실제 응답·도구 검사를 통과해야 합니다.

샌드박스 화면은 서비스 상태, 누락된 준비물, 고급 선택지를 보여줍니다. 서비스가
실행 중이어도 이미지 준비와 imp 부팅은 별개입니다. 새 백엔드를 고를 때 빠른
경로는 게스트 명령에 인터넷 접근을 허용합니다. 현재 설정된 백엔드를 선택하면
그 네트워크 정책을 유지하고, 고급 설정에서 명시적으로 바꿀 수 있습니다. 게스트
네트워킹을 끄면 샌드박스 명령에 영향이 있습니다. MASC 모델 연결과 WebFetch는
서버 쪽의 별도 네트워크 제어를 사용합니다.

```bash
masc setup                     # 연결·샌드박스 선택 다시 열기
masc doctor                    # 읽기 전용 준비 상태 보고
masc sandbox-catalog           # 호스트 샌드박스 선택지를 JSON으로 확인
```

준비 단계는 선택한 백엔드를 사용하고, 선택을 저장하기 전에 검증한 뒤 이 작업
공간의 서버를 시작하거나 연결합니다. 로컬 운영자 자격증명을 만들고 `imp`를
시작합니다. 이후 `masc`만 실행하면 모델 선택을 반복하지 않고 저장된 imp 기록을
엽니다. UI는 현재 서버·실행 상태를 별도로 관찰합니다. 기록이 남아 있다고 해서
현재 계정이나 샌드박스를 쓸 수 있다는 뜻은 아닙니다.

자동화에서는 작업 공간과 선택을 명시적으로 지정합니다. 예를 들어:

```bash
masc setup --base-path "$HOME/masc-workspace" --no-tui \
  --sandbox-profile docker --network-mode inherit
```

setup 여정을 나가도 준비된 서버는 계속 실행됩니다. 다른 작업 공간이 포트를 쓰고
있으면 `--port 8936`처럼 빈 포트를 지정하세요. 모델 선택은 현재 마법사 세션 안에서
로그인·재시도를 거쳐도 유지됩니다. "Finish later"를 고르면 이미 저장된 설정은
유지되며, 검사를 통과하지 못한 선택은 저장되지 않았습니다.

TUI에서 **Keepers → imp**를 선택하고 다음을 하나씩 요청하세요.

- “안녕. 대화가 연결됐는지 확인할 수 있게 답해줘.”
- “Board에 첫 대화라는 글을 작성하고 글 id를 알려줘.”
- “내 샌드박스 살펴보기라는 Task를 설명과 함께 만들고 id를 알려줘.”
- “네 샌드박스 안에서 `pwd`와 `ls`를 실행하고 디렉터리 목록을 보여줘.”
- “WebFetch로 지금 https://example.com 을 가져와서 HTTP 상태와 페이지 제목을 알려줘.”

답변, 저장된 Board 글과 Task, 샌드박스·웹 도구의 성공 결과를 확인하세요.
여기서는 대화와 기본 기능을 확인하며 Task 완료는 별도 절차입니다. Web fetch는
검색 API 키가 필요 없고 web search는 별도 검색 프로바이더 설정이 필요합니다.
도구 승인을 기다리면 채팅이나 **Approvals**에서 해당 요청을 확인하세요.
승인 대기나 HTTP 서버 응답만으로 모델 응답·도구 실행 성공을 판단하지 마세요.

MCP 서버만 필요하면 `masc start --base-path "$HOME/masc-workspace"`를 사용하고 [클라이언트 설정](../README.md#mcp-client-setup)을 따르세요.

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
  --network-mode none --activation-mode manual \
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
`browser-lanes`를 준비합니다. 모델과 샌드박스를 설정한 뒤 Keeper를 시작하세요.

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
Gecko scene 기능은 native host와 브라우저 확장 0.5.0 이상이 함께 있어야 합니다.
쓰던 브라우저 확장은 따로 갱신하세요.

`--team classic`을 선택하면 다음 네 Keeper TOML을 추가합니다.

| Keeper | 개별 지침의 역할 |
|---|---|
| `tech_lead` | 요구사항 분해, 역할 분배, diff/증거 검토 |
| `backend` | 백엔드 구현과 검증 |
| `frontend` | 프론트엔드 구현과 검증 |
| `qa` | 요구사항에 대한 테스트·검증 |

이 preset은 `activation_mode="autonomous"`, `sandbox_profile="docker"`,
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
검증된 커밋에 `v0.35.5` 태그를 push하면 네 빌드와 자산 검증을 거쳐 GitHub Release와
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

### 기존 workspace의 파일을 읽을 수 없는 경우

`masc setup`은 workspace 초기화, Docker 준비, 로그인, 서버 실행 전에 기존
Keeper 설정과 Goal 상태를 현재 스키마로 읽을 수 있는지 확인합니다. 읽을 수
없는 파일은 실제 경로와 파서 오류를 표시하고 기존 파일을 수정하지 않은 채
중단합니다. 구버전 파일을 보존했다는 사실이 새 버전과의 호환성을 뜻하지는
않습니다.

다음 중 하나를 선택하세요.

- 별도로 시작하려면 사용하지 않는 디렉터리를 골라
  앞에서 받은 검증된 installer로
  `bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-new-workspace" --wizard`를
  실행해 runtime을 선택합니다. 이어서
  `masc setup --base-path "$HOME/masc-new-workspace"`를 실행합니다. 원래 workspace는 그대로 남습니다.
- 원래 workspace를 검토하려면 setup을 중단하고 표시된 파일과
  `CHANGELOG.md`의 `Fresh state required` 항목을 확인합니다. 기존 로그는
  원래 workspace의 `.masc/logs`에 있습니다. 사용자가 의도적으로 파일을
  수정한 뒤에만 같은 workspace에서 setup을 다시 실행하세요.

Setup은 예전 Goal 파일을 삭제하거나 복구 사본을 덮어쓰지 않고, Keeper 설정을
자동 변환하지도 않습니다. 중단한 workspace가 준비됐다고 표시하지 않습니다.
