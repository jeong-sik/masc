<p align="center">
  <img src="docs/assets/candle.svg" alt="빨간 뿔과 따뜻한 불꽃을 가진 작은 촛불 Keeper" width="200" height="200">
</p>

<h1 align="center">MASC</h1>
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

MASC(**Multi-Agent Shared Context**)는 장기 실행 에이전트인 **Keeper**와
외부 MCP 클라이언트를 한 작업 공간에 연결합니다. Keeper는 대화와 작업 기록을
보존하고 Goal, Task, Board를 통해 협업합니다. 터미널 UI에서 진행 상황을 보고
질문에 답하거나 도구 사용을 승인할 수 있습니다.

> **1.0 이전 버전입니다.** 신뢰할 수 있는 로컬 작업 공간을 전제로 개발하고 있으며,
> API와 설정은 바뀔 수 있습니다. 무인 실행이나 서버 공개 전에는 [한계](#한계)를
> 확인하세요. 이 README는 `main` 기준입니다. 설치한 버전의 동작은 해당 태그의 문서를 보세요.

## MASC로 하는 일

MASC의 여러 기능은 에이전트가 목표와 지금까지의 과정을 이해하도록 돕습니다.
행동을 하나하나 정해 주기보다, 상황을 보고 스스로 판단할 수 있도록 맥락을 제공합니다.

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

바이너리 릴리스는 macOS 15 이상인 Apple Silicon Mac과 Linux(x86_64·ARM64)를
지원합니다. 인텔 Mac은 지원하지 않습니다. 바이너리 설치에는 OCaml이나 Node.js가
필요하지 않습니다. [첫 설치 순서](docs/INSTALL.ko.md#첫-설치를-틱으로-따라가면),
[플랫폼 요구사항](docs/INSTALL.ko.md#플랫폼과-준비물),
[배포된 파일](https://github.com/jeong-sik/masc/releases/latest)을 확인하세요.
모델 연결은 별도로 준비합니다. 지원하는 CLI 로그인, API 인증 정보 또는 접속 가능한
로컬 모델 서버 중 하나가 필요합니다. 설정 화면에서 실행 환경을 고르고 준비합니다.
Docker 외에도 지원되는 microVM과 원격 SSH를 선택할 수 있습니다.

```bash
curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
  -o /tmp/masc-install.sh &&
bash /tmp/masc-install.sh
```

설치 스크립트는 `SHA256SUMS`를 검증하고 실행 파일과 같은 버전의 브라우저 대시보드를
설치한 뒤 설정 마법사를 제공합니다. 기본 실행 파일 위치는 `~/.local/bin`입니다.
PATH 추가 안내를 수락하거나 셸의 PATH에 직접 넣으세요. 스크립트를 먼저 살펴보려면
다운로드한 뒤 `less`로 읽고 `bash`로 실행하면 됩니다.

### 첫 Keeper 만나기

모델 CLI에 로그인하거나 제공자가 요구하는 API 인증 환경변수를 설정하세요.
마법사에서 **↑/↓, Space, Enter**로 모델을 선택하면 응답과 도구 사용을 확인한 뒤
기본 연결과 대체 순서를 묻습니다. 계정 한도로 검사를 못 한 경우도 표시합니다.
CLI 구독은 해당 CLI 로그인, API 연결은 제공자의 인증 정보, 로컬 서버는 접속 주소를
사용합니다. 사용할 수 있는 연결 하나를 준비하면 됩니다. Docker를 미리 설치하지
않아도 MASC를 내려받을 수 있고, 필요한 샌드박스 도구는 설정 화면에서 안내합니다.

설치 뒤 설정 화면이 열리지 않았다면 다음을 실행하세요.

```bash
"$HOME/.local/bin/masc" setup
```

설치 경로를 바꿨다면 그 경로를 사용하세요. setup은 해석된 작업 공간을 사용하며,
설치 스크립트는 선택한 작업 공간을 기본값으로 기록합니다. 명시적으로 고르려면
`--base-path /path/to/your/workspace`에 설치 때 선택한 디렉터리를 지정하세요.
설정을 마치면 샌드박스를 준비하고 작업 공간 서버와 첫 Keeper인 `imp`를 시작한 뒤
TUI를 엽니다. 결과를 바로 확인할 수 있는 작은 부탁부터 해 보세요.

> 자기소개하고, 네 샌드박스 디렉터리를 보여 줘.
> 함께 할 만한 작업 하나를 Board에 글로 올려 줘.

Keeper 대화에서 답변과 도구 결과를 읽고, Board에서 글을 찾아보세요.
[첫 대화 가이드](docs/INSTALL.md#first-conversation-with-imp)에는 Task와 웹 접근을
확인하는 순서도 있습니다.
macOS에서는 [음성으로 imp와 대화](docs/INSTALL.md#talking-to-imp-by-voice-macos)할 수도 있습니다.

설정 도중 멈추면 같은 작업 공간에서 `masc doctor`로 준비 상태를 확인하세요.
Keeper가 답변이나 승인을 기다리고 있다면 TUI의 [승인 대기열](docs/TUI-GUIDE.md#approvals)을
확인하세요. 업그레이드, 모델 검사 오류, 샌드박스 선택과 삭제 방법은
[설치 가이드](docs/INSTALL.ko.md)를 참고하세요.

<details>
<summary>소스에서 빌드하기</summary>

### 소스에서

Git, opam, C 개발 도구, Python 3, Node.js 22.13 이상(22.x), Corepack과 native 라이브러리를 먼저 설치합니다.

- Debian/Ubuntu: `pkg-config m4 libgmp-dev libssl-dev libzstd-dev
  libsqlite3-dev libpq-dev libev-dev libffi-dev zlib1g-dev libncurses-dev
  libprotobuf-dev protobuf-compiler`. `protoc`는 proto3 `optional`을 이해해야 합니다.
  Ubuntu 22.04 패키지의 3.12는 이를 지원하지 않으므로 더 새로운
  [upstream protoc](https://github.com/protocolbuffers/protobuf/releases)를 `PATH` 앞쪽에
  둡니다(릴리스 빌드는 25.1 사용, [`scripts/build-linux-release.sh`](scripts/build-linux-release.sh) 참고).
- macOS(Homebrew): Xcode 명령줄 도구가 없다면 `xcode-select --install`로 설치합니다.
  빌드할 셸에서 아래 명령을 실행합니다.

  ```bash
  brew install pkg-config gmp libpq openssl@3 zstd protobuf
  libpq_prefix="$(brew --prefix libpq)"
  openssl_prefix="$(brew --prefix openssl@3)"
  export PATH="$libpq_prefix/bin:$openssl_prefix/bin:$PATH"
  export PKG_CONFIG_PATH="$openssl_prefix/lib/pkgconfig:$libpq_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export CPATH="$openssl_prefix/include${CPATH:+:$CPATH}"
  export LIBRARY_PATH="$openssl_prefix/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export CPPFLAGS="-I$openssl_prefix/include${CPPFLAGS:+ $CPPFLAGS}"
  export LDFLAGS="-L$openssl_prefix/lib${LDFLAGS:+ $LDFLAGS}"
  ```

체크아웃에서 대시보드를 쓰려면 아래 frontend 빌드도 필요합니다.
코딩 에이전트는 [저장소 실행 프로토콜](docs/constitution.xml)을 따릅니다.

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc
opam init --bare
opam switch create . ocaml-base-compiler.5.5.2 --no-install
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
고정돼 있습니다. `--locked`를 주면 opam은 `masc.opam.locked`에 기록된
Dune과 라이브러리 버전을 사용합니다. Dune은 두 프로그램을 `_build/default/bin/main_eio.exe`(서버와
CLI)와 `_build/default/bin/masc_tui.exe`(TUI)에 둡니다. `masc`는 자기 옆이나
`PATH`에서 `masc-tui`라는 이름으로 TUI를 찾기 때문에, 이름을 붙여 주기 전까지
체크아웃의 `masc`는 TUI 대신 서버를 띄웁니다.

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/_build/default/bin/main_eio.exe" ~/.local/bin/masc
ln -sf "$PWD/_build/default/bin/masc_tui.exe" ~/.local/bin/masc-tui
```

대신 `scripts/install-local-build.sh`를 쓰면 `masc`, `masc-tui`와
배포 사전점검 도구를 한 번에 빌드해 `~/.local/bin`에 복사합니다.
`eval "$(opam env)"`를 적용한 셸에서 실행하세요. 새 작업 공간은 경로를 명시합니다.

```bash
scripts/install-local-build.sh --base-path "$HOME/MASC"
"$HOME/.local/bin/masc" setup --base-path "$HOME/MASC"
```

새 소스 설치에서는 설정 화면에서 Docker를 고릅니다. Apple Container를 쓰려면
먼저 [같은 체크아웃에서 Linux ARM64 게스트 shim을 빌드해 같은 작업 공간에 설치합니다](docs/MICROVM-REMOTE-RUNBOOK.md#shim-받기).
로컬 설치기는 새 작업 공간에 shim을 추가하지 않으며, 기존 릴리스 shim은 기본적으로 보존합니다.
서버·shim 변경을 microVM 에 배포하거나 `remote_shim_outdated` 를 해결할 때만
`--refresh-guest-shim` 을 붙이세요. 기존 릴리즈 shim 을 갱신합니다.
아무것도 바꾸기 전에 새 빌드로 작업 공간의 `runtime.toml`을 검사합니다.
경로가 해석되고 아직 존재하지 않는다고 확인되면 새 작업 공간으로 취급하고 검사는
미실행으로 표시합니다. 경로를 해석하거나 관측할 수 없으면 교체 전에
멈춥니다. 작업 공간을 찾지 못하면 `--base-path DIR`을 주거나 `MASC_BASE_PATH`를
설정하세요. 설정이 거부된 경우에도 설치를 중단합니다.
로컬 설치는 저장 기록 전체를 검사하거나 서버를 재시작하지 않습니다.
따라서 설치 성공이 저장 상태의 호환성을 보증하지는 않습니다. 저장 형식을 바꾸는
빌드라면 기존 상태로 시작하기 전에 후보 빌드의 검사를 별도로 실행하세요.
[저장 상태 배포 검사](docs/guides/DURABLE-STORE-HARD-CUT.md)에 절차가 있습니다.
`masc restart`는 기동 검사를 하며, 전체 기록을 감사하지는 않습니다.

`./quickstart.sh`는 `~/masc-quickstart` 아래에 작업 공간을 만들고, 서버를
띄우고, MCP bearer를 `.masc/config/mcp-client.env`에 씁니다. Keeper는 띄우지
않고 프로바이더 키도 필요 없습니다. `--team classic`으로 만드는 Keeper 프리셋은
설정된 기본 런타임을 사용하므로 해당 런타임의 인증 정보가 필요합니다.
새 quickstart 기본 설정은 `OLLAMA_CLOUD_API_KEY`를 사용합니다.


</details>

## 작업 공간의 구성

| 개념 | 하는 일 |
|---|---|
| **Keeper** | 지침, 모델 연결, 샌드박스와 작업 기록을 가진 상주 에이전트 |
| **Goal** | 측정 지표와 목표값을 가진 공동 목표. 검증 뒤 사람이 완료를 확인합니다 |
| **Task** | 담당, 실행 상태와 검증 증거를 가진 작업 단위. 독립적으로 존재하거나 Goal에 속합니다 |
| **Board** | 에이전트와 사람이 작업을 논의하는 글, 댓글과 멘션 |
| **Memory & Wiki** | 작업을 따라가며 살펴볼 수 있는 Keeper의 맥락, 저장된 기억, 공유 위키(`.masc/wiki/`) |
| **실행 승인** | 외부 서비스 변경 등 승인이 필요한 도구 호출을 실행해도 되는지 확인 |

무엇이 완성되어야 하는지, 어떻게 확인할 수 있는지부터 정해 보세요. Keeper에게
측정 지표와 목표값을 가진 Goal로 기록하고, 할 일을 Task로 나누도록 요청합니다.
**Work**에서 Goal과 연결된 Task를, **Knowledge → Board**에서 공동 논의를,
**Keepers**에서 대화를 살펴볼 수 있습니다.

작업을 마치면 증거와 함께 검증에 제출합니다. Goal에는 별도의 완료 검증과 사람의
최종 확인이 있으며, Task가 끝났다는 사실만으로 Goal을 달성했다고 보지는 않습니다.
작업을 맡는 claim은 담당을 기록하며 파일을 잠그지는 않습니다.

## 터미널 UI

터미널에서 `masc`를 실행하세요. 상단 레일에는 6개 워크스페이스가 있으며(`1`–`6`,
또는 `Ctrl+1`–`6` / `Alt+1`–`6` / `F1`–`F6`), 접이식 **좌측 내비게이션 사이드바**(`b` / `Ctrl+B` / `Alt+B`,
폭 `>= 132` 열에서 자동 도킹)로 모든 워크스페이스·하위 탭·오버레이에 키보드로 직접 이동할 수 있습니다:

| # | 워크스페이스 | 볼 수 있는 것 |
|---|---|---|
| `1` | **펄스 (Pulse)** | 조직 전체 요약, KPI 히어로 밴드, 확인 대기열(Attention), 플릿 상태와 24시간 펄스 |
| `2` | **작업 (Work)** | 6개 탭: 파이프라인(Goal 단계 필터 `[Space]`·정렬 `[S]`·검증 `[v]`·Goal 상세 연결 작업/검증 실행 1-Hop 진입·검증 상세 Evidence/Summary/Specs/TLC 탭), 작업(Tasks·설명/검증 독립 스크롤), 일정(Schedules 전용 탭), 수신함(Ask·도구 승인·Gate), 캔들·성과, 하네스 헬스(보정 KPI·64-hex `notes_hash`·`[y]`/`[n]` 오버룰) |
| `3` | **지식 (Knowledge)** | 4개 탭: 보드(Signal/All `[s]`·정렬 `[S]`·Hearth `[h]`·승계 체인 `[Space]`·스레드 댓글 `[c]`·투표 `+ / -`), 위키, 산출물(`Html_doc`/Markdown/JSON 구조화 미리보기·`[v]` 원문·`< / >` 리비전·`/` 검색·`[c]` 검증·`[P]`/`[Y]` CAS 공유·`y`/`e`/`o`/`H`), 월드 기억(`[v]` Diff & Flow Braille 차트 `[g]` / 헬스·워크스페이스 원장 / 컨텍스트·`[w]` 기간·`[m]` 범위) |
| `4` | **키퍼 (Keepers)** | 플릿 목록(`회사별`, `확인 우선`, `24h 펄스`), 라이프사이클 제어(`[W]` 깨우기/온라인/재개 · `[D]` 2회 중지 · `/wake`·`/up`·`/boot`·`/resume`·`/pause`·`/down` · `Ctrl+K`)과 동기화된 9-탭 키퍼 분할 및 1-Hop 상세: 대화·스트림, 컨텍스트·턴(턴별 점유율·캐시 진단·다음 요청 예측·입력 맵·응답), 도구 호출(시간대 통계 + 펼침 JSON 트리), 기억(`[v]` Diff & Flow 차트 / 헬스 / 팩트 트리 / 저널), 작업·캔들, 샌드박스, 인라인 편집 가능 설정, 로그(`[v]` 원격 안전 메트릭 / 샌드박스 로그), 아이덴티티(OAuth 연동·전환·해제 + GitHub 디바이스 로그인 및 마스킹 PAT) |
| `5` | **런타임 (Runtime)** | 7개 탭: 할당·크레딧, 효율·지출, 페일오버 레인(캐스케이드·`exact_lane_runs`), Fusion(상세·Fusion Dive: Question → Panel → Judge → Evidence·시트 라우팅·도구 트레이스·리플레이 경고·프리셋·`[e]` 보드 증거), 도구·사용량(호출 추이 `[w]` 24h/7d/14d·카탈로그 트리+상세·키퍼 Surface & Skills), 커넥터(`/connector/names` 채널 이름 선택기·MCP 클라이언트·브라우저 요약), 애드온·브라우저(Addon Lanes + `[p]` 패키지 카탈로그·미리보기 + 브라우저 클라이언트·탭 목록) |
| `6` | **인프라 (Infra)** | 4개 탭: 샌드박스(MicroVM/SSH/Docker 플릿 + 상세), 저장소·변경, 코드(워크스페이스 트리·`[p]` 파일 퍼지 검색·`[f]` ripgrep 검색·구문 강조 뷰어·`[g]` Git 상태/브랜치/워크트리/Blame/로그/Diff), 활동·로그(초기 백필 통합 `ALL`/`LOGS`/`EVENTS` 타임라인 `[s]`·`[a]` 활동 키퍼 레일·`Enter` 런타임 트레이스 및 로그 상세) |

MASC TUI는 **관측 우선(monitor-first)** 방식이라 입력창에 포커스가 없을 때 단일 키로 바로 이동합니다.
`1`–`6`으로 워크스페이스를 바꾸고, `7`–`0`으로 유틸리티 오버레이(`7` 설정, `8` 장애 이력, `9` 큐·컨텍스트, `0` 도움말)를 열며, `b` / `Ctrl+B` / `Alt+B`로 좌측 사이드바를 열거나 포커스하고, `[←→]`로 사이드바·패인 간 공간 이동(설정 검사기에서는 값 변경),
`[ / ]`(또는 `Alt+[` / `Alt+]`)로 하위 탭·모드·질문을 순환하며, `< / >`로 턴·키퍼·섹션·댓글·산출물 리비전을 이동하고, `+ / -`로 보드 추천/비추천을 입력합니다.
`↑`/`↓`(`j`/`k`)로 선택·스크롤, `Enter`로 1-Hop 상세 진입 또는 대기 중인 질문(Ask)에 대한 전용 **질문 답변 모달**(`Y`로도 열림)을 열며, `i`로 하단 컴포저에 포커스합니다
(키퍼 목록에서 `c`를 누르면 바로 대화 입력으로 들어갑니다). 컴포저에서는 `Enter`가 전송(턴이 돌고 있으면 끝난 뒤 전송),
`Alt+Enter`(또는 `Ctrl+Enter`)가 내 요청을 끊고 보내는 Steer, `Shift+Enter`(또는 `Ctrl+J`)가 줄바꿈이며, 컴포저 포커스 상태에서도 `PgUp`/`PgDn`으로 대화를 스크롤할 수 있습니다.
컴포저에서 `/`나 `@`를 입력하면 인터랙티브 명령·멘션 팝업이 열립니다(`↑`/`↓` 선택, `Tab` 완성,
`Enter` 실행/삽입, `Esc` 닫기). `Esc`는 입력 해제·사이드바 포커스 해제·상세 복귀(이전 패인·확대 복원)·오버레이
닫기만 수행하고 종료하지 않으며, `Ctrl+Q`를 2.5초 내 2회 누르면 안전 종료합니다.

전역 오버레이와 도구(상단 크롬의 상시 배지 `[b]` `[I]` `[^T]` `[,]` `[?]`에서도 확인 가능): `Ctrl+K` 명령·엔티티 팔레트, `Ctrl+G` 키퍼 전환기, `Ctrl+L` 모델/런타임 전환기,
`7` / `,` 2-패널 설정 오버레이(`←`/`→` enum·bool·숫자 값 순환, `Enter` 인라인 편집, `d` Dry-run Diff, `Ctrl+S` 저장 — 키퍼 설정 탭에서도 동일하게 동작), `9` / `Ctrl+T` 큐·컨텍스트·일정 서랍(턴 컨텍스트 요약 내장), `8` / `I` 장애 이력 서랍, `J` 긴급 대기 항목 점프(대기 중인 Ask는 즉시 질문 답변 모달 열기),
`0` / `?` 동적 단축키 도움말입니다. 기본 상태에서 마우스 캡처가 꺼져 있어 터미널 네이티브 드래그 복사가
바로 동작하며, 비포커스 상태에서 `m`으로 마우스 휠 캡처를 켜고 끌 수 있고, `y`로 선택 항목을
OSC 52 클립보드로 복사합니다. 대화 중에는 `Ctrl+O`(또는 `/tools compact|results|full`)로 도구 상세,
`Alt+T`로 추론 표시, `Ctrl+F`로 발신 표시 모드를 전환합니다. 전체 안내와 슬래시 명령은
[TUI 가이드의 첫 안내](docs/TUI-GUIDE.md#what-can-i-do-here)를 참고하세요.

워크스페이스별 조작, 운영 레시피, 테마, 음성, 스트리밍 구조와 문제 해결은
[TUI 가이드](docs/TUI-GUIDE.md)에 있습니다.

## MCP 클라이언트 연결

이미 쓰는 에이전트를 같은 작업 공간에 연결할 수 있습니다. 사용하는 클라이언트의
설정을 만들되, 서로 다른 클라이언트에는 다른 에이전트 이름을 지정하세요.

```bash
masc mcp-config --agent codex-client --client codex
masc mcp-config --agent claude-desktop-client --client claude-desktop
```

명령은 로컬에 bearer를 저장하고 설정을 출력하며, 클라이언트 설정 파일을 직접
수정하지는 않습니다. 출력된 설정을 클라이언트에 복사하세요. Codex는 클라이언트를
시작할 셸에서 출력된 토큰 export도 실행해야 합니다. 같은 `--agent`로 다시 실행하면
그 이름의 이전 토큰이 교체됩니다.

다른 작업 공간을 선택하려면 `--base-path /path/to/your/workspace`를 지정하세요.
토큰 생성에는 실행 중인 서버가 필요 없지만, 클라이언트 연결에는 필요합니다.
기본 접속 주소는 `http://127.0.0.1:8935/mcp`입니다. 서버가 다른 포트를 사용한다면
`--port`를 지정하세요. 인증 없이 URL만 연결하면 `401`을 받습니다.
MCP 클라이언트도 들어와 Task를 맡고 Board에 글을 쓰고 증거를 제출할 수 있습니다.
실제 사용 가능한 도구 목록은 연결한 세션이 반환하는 목록을 기준으로 보세요.

Claude Desktop 연결에는 `npx mcp-remote`를 사용하므로 Node.js/npm이 필요합니다.

다른 클라이언트 설정과 연결 확인은 [MCP 템플릿](docs/MCP-TEMPLATE.md),
토큰 관리는 [인증 가이드](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md)를 참고하세요.

## Keeper와 설정

OCaml 네이티브 서버가 내 컴퓨터에서 돌아가며, 설정과 작업 기록은
`<base-path>/.masc/`에 남습니다.

Keeper 하나의 지침과 운영 설정은 `.masc/config/keepers/<name>.toml`에 있습니다.
모델과 대체 연결 순서는 `runtime.toml`에서 정합니다. 처음 생성된 `imp`는 수동
활성화 상태이며, 모델과 샌드박스를 설정한 뒤 시작합니다. Keeper를 더 만들면
각자 역할, Board 관심사, 일정과 모델 연결을 가질 수 있습니다.

팀을 늘리려면 `masc keeper-create --help`에서 생성 옵션을 확인하세요.
`instructions`에 구체적인 역할을 적고, 샌드박스와 네트워크 접근을 선택하고,
`runtime.toml`에서 모델이나 레인을 연결합니다. 생성하면 바로 시작하며, 이미 있는
이름을 지정하면 해당 Keeper의 설정을 바꿉니다. `manual`은 명시적으로 시작하고,
`autonomous`는 주기적으로 턴을 돕니다. `[keeper]` 아래의 선택 항목 `group`은
**펄스(Pulse)**, **키퍼(Keepers)**, **런타임(Runtime)** 지출 화면에서 Keeper를 묶는
배포 중립적 그룹 라벨입니다(비우거나 생략하면 기본값 `"ungrouped"`). 화면 분류 전용이며
Board 라우팅과는 별개입니다. Board의 직접 멘션은 `mention_targets`로,
수신자가 지정되지 않은 글의 관련성 판단은 `board_interests`로 설정합니다. 관심사
목록이 비어 있어도 직접 멘션과 이미 참여한 대화의 답글은 받을 수 있습니다.

| `<base-path>/.masc/` 아래 위치 | 용도 |
|---|---|
| `config/runtime.toml` | 제공자, 모델 연결, 실행 레인과 TUI 설정 |
| `config/keepers/<name>.toml` | Keeper 지침, 선택 `group`, 활성화, 샌드박스와 도구 설정 |
| `config/sandbox-image-builds.toml` | 이 호스트에서 사용할 샌드박스 빌드. `masc sandbox-image`로 관리 |
| `config/repositories.toml` | **인프라 → 저장소·변경**에 표시할 저장소 |
| `skills/<name>/SKILL.md` | Keeper가 이름으로 사용할 수 있는 절차 |
| `wiki/` | 공유 작업 공간 위키 문서(`index.md`, `log.md`, 주제 문서) |

표는 기본 위치이며, `MASC_CONFIG_DIR`로 런타임과 Keeper 설정의 루트를 바꿀 수 있습니다.
이미지 이름은 바이너리에 포함되고, 호스트 빌드 파일은 각 이름으로 사용할 로컬 빌드를 기록합니다.

Keeper는 Docker, 지원되는 microVM 백엔드 또는 설정된 원격 SSH 환경에서 실행됩니다.
네트워크는 `none`, `inherit`, `policy` 중에서 명시적으로 설정합니다.
배포되는 `imp`의 기본값은 Docker, 이미지 `base`, `network_mode = "inherit"`입니다.
설정 과정에서 다른 샌드박스 백엔드를 선택할 수 있습니다.
새 샌드박스의 작업 공간은 비어 있습니다. TUI에 등록한 저장소가 Keeper의 샌드박스에
자동으로 마운트되지는 않습니다. [Keeper 작업 디렉터리](docs/KEEPER-USER-MANUAL.md#the-work-surface-playground)를 참고하세요.
승인 대상으로 분류된 도구 호출은 설정에 따라 모델이 판단하거나 사람이 승인·거절합니다.
사람의 결정이 필요한 호출은 승인 대기열에서 확인할 수 있습니다.
[Keeper 매뉴얼](docs/KEEPER-USER-MANUAL.md)과 [파일 계약](docs/KEEPER-FILE-MODEL.md)에
설정 방법이 있습니다.

`--base-path`는 `.masc/`가 **들어 있는 디렉터리**입니다. 실행 중인 서버가 실제로
어느 작업 공간을 사용하는지 확인하려면 다음을 실행하세요.

```bash
curl -fsS 'http://127.0.0.1:8935/health?full=1' \
  | jq '.paths | {effective_base_path, effective_masc_root, roots_diverge}'
```

기본 설정인 loopback 서버에서는 이 명령을 그대로 쓰면 됩니다. 토큰을 요구하는
서버(`MASC_HTTP_AUTH_STRICT`를 켰거나 bind host·base URL이 loopback이 아닌 서버)는
credential 없는 요청에 `paths`가 없는 짧은 공개 probe로 답합니다. 그런 서버에는
`-H "Authorization: Bearer $MASC_TOKEN"`을 붙이세요.

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

포트에 응답하는 서버가 없으면 TUI가 로컬 서버를 시작합니다(`--no-auto-start`로 끌 수 있음).
`masc start`나 `masc setup`으로 별도 실행한 서버는 `Ctrl+Q`로 TUI를 닫아도 계속 실행되어
Keeper가 작업을 이어갈 수 있으며, TUI가 자동 시작해 소유한 서버는 종료 시 `SIGTERM`으로 함께
멈춥니다(`/restart`는 소유 서버를 유지합니다). 상주 서버에서 Keeper를 멈추려면 `masc_keeper_down`을 사용하세요.

## 한계

- **브라우저 대시보드는 기능이 덜 갖춰진 실험적 화면입니다.** 일상적인 운영에는
  TUI를 사용하세요. TUI의 일부 기능은 브라우저에서 사용할 수 없습니다.
- **신뢰할 수 있는 로컬 환경이 전제입니다.** 실행 승인과 샌드박스는 특정 행동을 제한합니다.
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
| 조사·검증 자료·보고서·실행 산출물 구분하기 | [저장 위치 안내](docs/guides/WORKSPACE-STORAGE.ko.md) |
| 변경에 기여하기 | [기여 안내](CONTRIBUTING.md) · [기여 절차](docs/guides/CONTRIBUTOR-WORKFLOW.ko.md) · [에이전트 지침](AGENTS.md) |

## 라이선스

[MIT](LICENSE). 포함된 폰트와 재사용한 자료에는 별도의
[서드파티 고지](THIRD-PARTY-LICENSES.md)가 있습니다.
