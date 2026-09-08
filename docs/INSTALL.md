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

관리자 패키지 설치는 운영자가 실행합니다. MASC 설치 스크립트는 `sudo`나
패키지 관리자를 자동 실행하지 않습니다. macOS의 Homebrew 라이브러리 경로는
해당 CPU의 기본 prefix를 사용합니다. 실제 로더 실패가 나면 그 오류를 기준으로
누락 라이브러리를 보충하세요.

## 설치

```bash
TAG=v0.34.0
curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/${TAG}/scripts/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh
bash /tmp/masc-install.sh --version "$TAG" --base-path "$HOME/masc-workspace"
export PATH="$HOME/.local/bin:$PATH"
```

`--prefix` 기본값은 `$HOME/.local/bin`, `--base-path` 기본값은 설치 명령을
실행한 디렉터리입니다. `.masc`는 지정한 base path 아래에 생깁니다. 설치 위치와
작업 데이터 위치는 독립적입니다. 스크립트와 자산은 반드시 같은 태그를 사용합니다.
체크섬이 없거나 불일치하면 설치를 중단합니다.

`--no-wizard`는 모델 선택을 건너뜁니다. `--provider <id>`는
`runtime.toml`의 공급자 catalog에서 선택합니다. 마법사는 사용 가능한 모델 서버와
CLI 인증 상태를 탐지하고 `[runtime].default`를 선택하며 API 키는 저장하지 않습니다.
모델이 없어도 서버 설치와 상태 화면 사용은 가능합니다.

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

기본 Keeper 명단은 비어 있습니다. 모델 가중치, 모델 CLI, API 키, Docker,
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
curl http://127.0.0.1:8935/health
curl 'http://127.0.0.1:8935/health?full=1'
```

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

Keeper는 설정된 모델로 턴을 수행하고, sandbox에서 도구를 실행하며, 작업·보드·채팅을
통해 협업합니다. 일정 실행, 승인 판단, 외부 connector와 브라우저 조작은 해당
runtime/credential/backend 설정이 있어야 합니다. 브라우저는 별도
[native host 연결 안내](../connectors/browser/host/README.md)를 따릅니다.
서버 설치 smoke는 모델 응답이나 장시간 Keeper 연속 실행을 증명하지 않습니다.

## 업그레이드와 복구

같은 태그의 스크립트를 새로 받은 뒤, 기존과 같은 prefix/base path로 실행합니다.

```bash
bash /tmp/masc-install.sh --version "$TAG" \
  --base-path "$HOME/masc-workspace" --force --no-wizard
```

0.34.0부터 `--force`는 바이너리를 갱신하며 기존 runtime 설정, 모델 선택,
Keeper 파일을 보존합니다. 누락된 기본 설정은 보충합니다. 설정 초기화가 목적일
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

`workflow_dispatch`는 브랜치 artifact 검증용이며 공개 릴리스를 생성하지 않습니다.
검증된 커밋에 `v0.34.0` 태그를 push하면 네 빌드와 자산 검증을 거쳐 GitHub Release와
`SHA256SUMS`를 게시합니다. 태그, CI 성공, 실제 release assets, 설치 후 실행 결과는
각각 확인해야 합니다.
