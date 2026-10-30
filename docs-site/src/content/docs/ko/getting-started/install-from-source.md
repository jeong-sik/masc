---
title: 소스에서 빌드하기
description: OCaml 소스에서 MASC 서버와 터미널 UI 를 직접 빌드합니다. 기여자나 미공개 빌드가 필요할 때 씁니다.
---

대부분은 [미리 빌드된 바이너리](/ko/getting-started/quickstart/)를 설치하면 됩니다.
소스에서 빌드하는 건 코드에 기여할 때나, 최신
[릴리즈](https://github.com/jeong-sik/masc/releases)보다 더 새로운 빌드가 필요할
때입니다. 소스 빌드는 OCaml 서버와 대시보드를 컴파일하므로 몇 분 걸립니다.

## 준비물

- **macOS 또는 Linux**
- **OCaml** 5.5.1, `opam` 포함
- **Node.js** 22+ (웹 대시보드에만 필요)
- **Native 라이브러리** (gmp, OpenSSL, zstd, SQLite, libpq, libev, libffi, zlib,
  ncurses, proto3 `optional`을 지원하는 `protoc`): OS별 패키지 목록은
  [README](https://github.com/jeong-sik/masc/blob/main/README.ko.md#소스에서)에 있습니다

## 1. 클론하고 의존성 설치

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc

# 의존성을 풀기 전에 로컬 OCaml switch 만 만들기
opam switch create . ocaml-base-compiler.5.5.1 --no-install
eval "$(opam env)"

# OCaml 의존성을 CI 와 같은 버전으로 고정 및 설치
scripts/opam-pin-external-deps.sh
opam install ./masc.opam --deps-only --locked
```

## 2. 작업 공간 서버 켜기

`./quickstart.sh`는 `~/masc-quickstart` 아래에 `.masc/` 작업 공간을 초기화하고 MCP bearer 토큰을 `.masc/config/mcp-client.env`에 기록한 뒤 서버를 띄웁니다. 기본적으로 Keeper는 시작하지 않으며, `--team classic`을 넘기지 않는 한 API 키가 필요하지 않습니다.

```bash
./quickstart.sh
```

켜지면 다음 주소가 열립니다.

- **MCP 엔드포인트**: `http://127.0.0.1:8935/mcp`
- **대시보드 (실험 기능)**: `http://127.0.0.1:8935/dashboard/`
- **헬스 체크**: `curl http://127.0.0.1:8935/health`

## 3. 서버 및 터미널 UI 직접 빌드·열기

체크아웃한 소스에서 서버(`bin/main_eio.exe`)와 TUI(`bin/masc_tui.exe`)를 함께 빌드해 실행합니다.

```bash
dune build bin/main_eio.exe bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/masc-quickstart
```

키와 화면은 미리 빌드된 바이너리와 같습니다.
[터미널에서 조작하기](/ko/guides/tui/)를 보세요.

## 4. 자율 Keeper 켜기 (선택)

미리 빌드된 설치와 마찬가지로, Keeper는 모델 런타임과 명령 격리가 필요합니다.
`masc` 명령을 쓰기 전에 소스 실행 파일과 동반 도구를 함께 설치하세요.
위 quickstart에서 사용한 작업 공간을 그대로 이어갑니다.

```bash
scripts/install-local-build.sh --base-path "$HOME/masc-quickstart"
"$HOME/.local/bin/masc" setup --base-path "$HOME/masc-quickstart"
# 또는 설정이 완료된 뒤 서버만 바로 시작:
"$HOME/.local/bin/masc" start --base-path "$HOME/masc-quickstart"
```

설치 스크립트는 서버, TUI, browser host와 배포 사전 점검 도구를 빌드해
`~/.local/bin`에 설치합니다. `--prefix`를 넘겼다면 선택한 실행 파일 경로를
사용하세요. setup은 모델 연결과 선택한 sandbox를 준비하고 TUI를 엽니다.
브라우저 대시보드도 쓰려면
[README](https://github.com/jeong-sik/masc/blob/main/README.ko.md#소스에서)의
대시보드 빌드 안내를 따르세요.

키 없이 쓰는 방법은 [로컬 AI 모델 연결](/ko/runbooks/llama-server/)을, 격리
요건은 [명령어 안전 격리](/ko/runbooks/sandbox/)를 보세요.
