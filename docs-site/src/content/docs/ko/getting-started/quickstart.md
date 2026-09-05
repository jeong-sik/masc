---
title: 빠른 시작
description: 빌드 도구 없이, 미리 빌드된 MASC 바이너리를 설치해 서버와 터미널 UI 를 띄웁니다.
---

이 문서는 **미리 빌드된 바이너리**를 설치해 서버와 터미널 UI 까지 띄우는 과정을
안내합니다. OCaml 이나 Node.js 같은 빌드 도구는 필요 없습니다. 소스에서 직접
빌드하려면 [소스에서 빌드하기](/ko/getting-started/install-from-source/)를 보세요.

단계는 두 층이고, 첫 층까지만 해도 됩니다.

1. **이미 쓰는 AI 도구를 위한 협업 서버.** API 키도, Docker 도 필요 없습니다.
   설치하고 서버를 켠 뒤 Claude Code 나 Cursor 를 MCP 로 연결하면 됩니다.
2. **자율 Keeper.** 스스로 작업을 맡아 파일을 고치는 장기 실행 에이전트입니다.
   여기엔 모델 소스와 명령 격리(sandbox) 두 가지가 더 필요합니다.

## 준비물

- **macOS 또는 Linux.** (Windows 는 지원하지 않습니다.)
- **터미널.** macOS 는 응용 프로그램 → 유틸리티에서 **터미널**을 열거나,
  `Cmd`+`Space` 를 눌러 "터미널"을 검색하면 됩니다. Linux 는 터미널 앱을 엽니다.

첫 층은 이게 전부입니다.

## 1. 바이너리 설치

[릴리즈 목록](https://github.com/jeong-sik/masc/releases)에서 최신 태그
(예: `v0.31.0`)를 고르고, **같은 태그**의 설치 스크립트를 씁니다. 아래 `vX.Y.Z`
자리에 고른 태그를 넣으세요.

```bash
TAG=vX.Y.Z
curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/${TAG}/scripts/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh      # 먼저 내용을 확인하세요. q 를 누르면 나옵니다
bash /tmp/masc-install.sh --version "$TAG"
```

설치 스크립트는 바이너리를 받아 `SHA256SUMS` 로 무결성을 확인하고, `masc` 와
`masc-tui` 를 `~/.local/bin` 에 놓습니다. 그다음 일회성 설정 마법사가
[3단계](#3-서버-켜기)로 이어집니다. 마법사를 건너뛰려면 `--no-wizard` 를 붙이세요.

## 2. `masc` 를 PATH 에 넣기

바이너리는 `~/.local/bin` 에 놓이는데, 갓 설치한 기기에서는 이 경로가 `PATH` 에
없는 경우가 많습니다. `masc --help` 가 "command not found" 라고 나오면, 이 경로를
셸 시작 파일에 추가하세요.

먼저 어떤 셸을 쓰는지 확인합니다.

```bash
echo $SHELL
```

끝이 `zsh` 이면 (macOS 기본):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

끝이 `bash` 이면 (Linux 에서 흔함):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

그다음 확인합니다.

```bash
masc --help
```

새 터미널 창을 여는 것도 `source` 와 같은 효과가 있습니다.

## 3. 서버 켜기

설치가 끝나면 스크립트가 각자 환경에 맞는 시작 명령을 찍어줍니다. 모양은 아래와
비슷하고, 이 명령은 **앞단(foreground)에서 돕니다** — 서버가 도는 동안 그 터미널은
서버가 붙잡고 있습니다.

```bash
masc --base-path ~/.masc
```

서버가 이 터미널을 붙잡고 있으니, 아래 단계는 **새 터미널 창을 하나 더 열어서**
진행하세요. 새 터미널에서 서버가 응답하는지 확인합니다.

```bash
curl http://127.0.0.1:8935/health
```

정상이면 `{"status":"ok",...}` 가 돌아옵니다. 브라우저에서
`http://127.0.0.1:8935/dashboard/` 대시보드도 열 수 있습니다.

## 4. 터미널 UI 열기

터미널 UI 는 운영자용 조종석입니다. 대화형 터미널이 필요합니다.

```bash
masc-tui --port 8935
```

- `Tab` / `Shift-Tab` 로 화면(Keepers, Board, Approvals …)을 넘깁니다.
- `:` 로 명령 팔레트를 엽니다.
- `q` 를 두 번 누르면 나갑니다.

화면 종류와 키는 [터미널에서 조작하기](/ko/guides/tui/)에 정리돼 있습니다.

## 5. AI 도구 연결 (여기까지가 첫 층)

서버는 `http://127.0.0.1:8935/mcp` 에서 MCP 로 말합니다. Claude Code, Cursor 같은
MCP 클라이언트를 여기에 연결하면 하나의 `.masc/` 작업 공간을 함께 씁니다. 각 도구가
자기 모델을 들고 오므로 모델 키는 필요 없습니다. 이 엔드포인트는 bearer 토큰을
요구하는데, 그 토큰을 만드는 `masc login` 명령도 설치 스크립트가 찍어줍니다.

연결 방법은 [Claude Code · Cursor 연동](/ko/guides/mcp-clients/)을 따르세요.

## 6. 자율 Keeper 켜기 (선택)

Keeper 는 MASC 가 직접 돌리는 에이전트입니다. 두 가지가 더 필요합니다.

- **모델 소스** — Keeper 가 한 턴을 돌릴 모델입니다. 가장 저렴한 방법은 API 키가
  필요 없는 로컬 모델입니다. Ollama 나 `llama-server` 를 띄우는 법은
  [로컬 AI 모델 연결](/ko/runbooks/llama-server/)을 보세요. 클라우드 프로바이더
  (Anthropic, OpenAI, DeepSeek …)도 되고, 그 API 키는 1단계 마법사가
  `.masc/config/.env.local` 에 저장합니다.
- **명령 격리(sandbox)** — Keeper 의 셸 명령은 여러분 기기가 아니라 격리된
  공간에서 돕니다. 격리가 없으면 MASC 는 Keeper 를 띄우지 않습니다. Docker 를
  설치하거나, Apple Silicon 이면 `container` CLI 를 씁니다.
  [명령어 안전 격리](/ko/runbooks/sandbox/)를 보세요.

둘 다 준비되면 TUI 의 **Keepers** 화면에서 첫 Keeper 를 만들거나, 명령줄에서
`masc keeper-create --help` 로 만듭니다. [Keeper 사용하기](/ko/guides/keeper/)에
자세히 나옵니다.

## 잘 안 될 때

[문제 해결](/ko/runbooks/troubleshooting/)을 보세요. 첫 실행에서 가장 흔한 문제는
`masc: command not found` (2단계, PATH)와, 기본 모델 소스에 닿지 못해 서버가 안
켜지는 경우(6단계)입니다.
