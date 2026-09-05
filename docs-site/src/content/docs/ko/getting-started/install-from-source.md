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
- **OCaml** 5.5.0, `opam` 포함
- **Node.js** 22+ (웹 대시보드에만 필요)

## 1. 클론하고 의존성 설치

```bash
git clone https://github.com/jeong-sik/masc.git
cd masc

# OCaml 의존성 고정 및 설치
scripts/opam-pin-external-deps.sh --install
opam install . --deps-only
```

## 2. 작업 공간 서버 켜기

`quickstart.sh` 는 `~/masc-quickstart` 아래에 `.masc/` 작업 공간을 만들고 서버를
띄웁니다.

```bash
./quickstart.sh
```

켜지면 다음 주소가 열립니다.

- **MCP 엔드포인트**: `http://127.0.0.1:8935/mcp`
- **대시보드**: `http://127.0.0.1:8935/dashboard/`
- **헬스 체크**: `curl http://127.0.0.1:8935/health`

## 3. 터미널 UI 열기

체크아웃한 소스에서 TUI 를 빌드해 실행합니다.

```bash
dune build bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/masc-quickstart
```

키와 화면은 미리 빌드된 바이너리와 같습니다.
[터미널에서 조작하기](/ko/guides/tui/)를 보세요.

## 4. 자율 Keeper 켜기 (선택)

미리 빌드된 설치와 마찬가지로, Keeper 는 모델 소스와 명령 격리가 필요합니다.
프로바이더 키를 넣거나(또는 로컬 모델을 연결하고) 서버를 띄웁니다. `--base-path`는 필수입니다.

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
./start-masc.sh --http --base-path ~/masc
```

키 없이 쓰는 방법은 [로컬 AI 모델 연결](/ko/runbooks/llama-server/)을, 격리
요건은 [명령어 안전 격리](/ko/runbooks/sandbox/)를 보세요.
