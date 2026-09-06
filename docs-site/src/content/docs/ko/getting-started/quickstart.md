---
title: 빠른 시작
description: 빌드 도구 없이, 미리 빌드된 MASC 바이너리를 설치해 서버와 터미널 UI 를 띄웁니다.
---

이 문서는 **미리 빌드된 바이너리**를 설치해 서버와 터미널 UI 까지 띄우는 과정을
안내합니다. OCaml 이나 Node.js 같은 빌드 도구는 필요 없습니다. 소스에서 직접
빌드하려면 [소스에서 빌드하기](/ko/getting-started/install-from-source/)를 보세요.

설치는 두 단계로 나뉘고, 첫 단계까지만 해도 쓸 수 있습니다.

1. **이미 쓰는 AI 도구를 위한 협업 서버.** API 키도, Docker 도 필요 없습니다.
   설치하고 서버를 켠 뒤 Claude Code 나 Cursor 를 MCP 로 연결하면 됩니다.
2. **자율 Keeper.** 스스로 작업을 맡아 파일을 고치는 장기 실행 에이전트입니다.
   여기엔 모델 소스와 명령 격리(sandbox) 두 가지가 더 필요합니다.

## 준비물

- **macOS 또는 Linux.** (Windows 는 지원하지 않습니다.)
- **터미널.** macOS 는 응용 프로그램 → 유틸리티에서 **터미널**을 열거나,
  `Cmd`+`Space` 를 눌러 "터미널"을 검색하면 됩니다. Linux 는 터미널 앱을 엽니다.

첫 단계는 여기까지입니다.

## 1. 바이너리 설치

[릴리즈 목록](https://github.com/jeong-sik/masc/releases)에서 최신 태그
(예: `v0.31.0`)를 고르고, **같은 태그**의 설치 스크립트를 씁니다. 아래 `vX.Y.Z`
자리에 고른 태그를 넣으세요.

```bash
TAG=vX.Y.Z
curl -fsSL "https://raw.githubusercontent.com/jeong-sik/masc/${TAG}/scripts/install.sh" \
  -o /tmp/masc-install.sh
less /tmp/masc-install.sh      # 먼저 내용을 확인하세요. q 를 누르면 나옵니다
bash /tmp/masc-install.sh --version "$TAG" --base-path ~/masc
```

설치 스크립트는 바이너리를 받아 `SHA256SUMS` 로 무결성을 확인하고, `masc` 와
`masc-tui` 를 `~/.local/bin` 에 놓습니다.

`--base-path ~/masc` 는 작업 공간이 놓일 자리입니다. 설치가 `~/masc/.masc/` 를
만들고, 아래 명령들은 모두 `~/masc` 를 가리킵니다. `--base-path` 를 안 주면 작업
공간이 설치 스크립트를 실행한 디렉터리에 생겨 나중에 찾기 어렵습니다 — 한 번
정해두면 이후 명령이 전부 같아집니다. 설치가 끝나면 이 경로가 채워진 시작·login·TUI
명령도 스크립트가 찍어줍니다.

그다음 일회성 설정 마법사가 이어집니다. 마법사를 건너뛰려면 `--no-wizard` 를 붙이세요.

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

## 3. 켜기

명령 하나입니다. 앞으로도 계속 쓸 터미널에서:

```bash
masc --base-path ~/masc
```

서브커맨드 없는 `masc` 가 들어가는 문입니다. 터미널에서는 터미널 UI 로 넘겨주고,
UI 가 열릴 때 듣고 있는 서버가 없으면 그때 뒤에서 서버를 띄웁니다. 서버를 따로
켜지 않고, 명령도 두 번 치지 않습니다.

사람이 안 보는 자리에서는 다르게 굽니다. 일부러 그렇습니다.

| 어디서 실행하나 | 무슨 일이 생기나 |
| --- | --- |
| 터미널 | 터미널 UI 가 열리고, 서버는 그 뒤에서 뜹니다 |
| 파이프, systemd 유닛, CI 단계 | 서버가 앞단에서 돕니다 |
| `--host` 가 `127.0.0.1` 이 아닐 때 | 서버가 앞단에서 돕니다 |

그래서 같은 명령이 운영자 화면이자 서비스 진입점입니다. 서버 쪽을 직접 보고
싶으면 파이프로 넘기세요. `masc --base-path ~/masc | cat`

UI 안에서는:

- `Tab` / `Shift-Tab` 로 화면(Keepers, Board, Approvals …)을 넘깁니다.
- `:` 로 명령 팔레트를 엽니다.
- `q` 를 두 번 누르면 나갑니다.

화면 종류와 키는 [터미널에서 조작하기](/ko/guides/tui/)에 정리돼 있습니다.

## 4. 서버가 응답하는지 보기

터미널을 하나 더 열거나, UI 를 닫은 뒤에:

```bash
curl http://127.0.0.1:8935/health
```

정상이면 `{"status":"ok",...}` 가 돌아옵니다. 대시보드는
`http://127.0.0.1:8935/dashboard/` 입니다.

`install.sh` 없이 손으로 설치했다면, 위 단계들 전에 작업 공간을 한 번 심어야
합니다.

```bash
masc init --base-path ~/masc
```

런타임 설정, 프롬프트, 도구 정의, 테마, 커넥터 선언 — 설정 트리를 **바이너리
안에서** 꺼내 씁니다. 저장소를 받아본 적 없는 기계에서도 됩니다. 파일 271개를
쓰고 `config/keepers/` 는 일부러 비워 둡니다. 아래에서 설명합니다.

## 5. AI 도구 연결 (여기까지가 첫 단계)

서버는 `http://127.0.0.1:8935/mcp` 에서 MCP 로 말합니다. Claude Code, Cursor 같은
MCP 클라이언트를 여기에 연결하면 하나의 `.masc/` 작업 공간을 함께 씁니다. 각 도구가
자기 모델을 들고 오므로 모델 키는 필요 없습니다. 이 엔드포인트는 bearer 토큰을
요구하는데, 그 토큰을 만드는 `masc login` 명령도 설치 스크립트가 찍어줍니다.

연결 방법은 [MCP 클라이언트 연결](/ko/guides/mcp-clients/)을 따르세요.

작업 공간은 토큰의 SHA-256 만 들고 있습니다. 그래서 bearer 원문이 남아 있는 곳은
`.masc/auth/<agent>.token`(권한 `0600`) 하나뿐입니다. 뭐가 있는지 보고 하나를
폐기하려면:

```bash
masc token list                 # agent, 역할, 만료, 원문이 아직 디스크에 있는지
masc token revoke --agent NAME  # 자격증명 삭제
masc token prune                # 만료된 것만 삭제
```

같은 agent 이름으로 다시 발급하면 자격증명이 교체됩니다. 그게 회전입니다. 읽을 수
없는 만료 시각은 살아 있는 것으로 칩니다. prune 이 아직 되는 토큰을 지우는 일은
없습니다.

## 6. 자율 Keeper 켜기 (선택)

Keeper 는 MASC 가 직접 돌리는 에이전트입니다. 설치가 끝나도 **Keeper 는 한 명도
없습니다** — 명단은 작업 공간마다 다르니 설치 스크립트도 서버도 지어내지 않습니다.
첫날에 없는 게 셋이고, Keeper 는 셋 다 필요합니다.

**모델을 대는 곳.** 시드된 카탈로그에는 제공자 다섯이 있고, 키 없이 되는 건 하나뿐입니다.

| 제공자 | 주소 | 환경변수 |
| --- | --- | --- |
| `ollama_cloud` | `ollama.com/v1` | `OLLAMA_CLOUD_API_KEY` |
| `deepseek` | `api.deepseek.com` | `DEEPSEEK_API_KEY` |
| `glm-coding` | `api.z.ai/api/coding/paas/v4` | `ZAI_API_KEY_SB` |
| `kimi_coding` | `api.kimi.com/coding/v1` | `KIMI_API_KEY` |
| `ollama` | `localhost:11434` | 없음 — [로컬 모델](/ko/runbooks/llama-server/) |

이 변수는 **서버를 띄운 그 환경**에서 읽습니다. 설정 파일이 아닙니다. MASC 는 키를
묻지 않고 디스크에 쓰지도 않습니다.

카탈로그에는 제공자·모델 바인딩 31개가 예시를 겸해 들어 있습니다. 31개 모두
`max-request-body-bytes` 가 선언되어 부팅 경고 없이 Keeper 턴을 받을 수 있습니다.
`[runtime].default` 가 바로 돌 수 있도록 준비되어 있습니다.

**샌드박스 이미지.** Keeper 는 매 턴을 이미지 안에서 돌리는데, MASC 는 이미지를
같이 배송하지 않습니다.

```bash
masc sandbox-image
```

`masc-sandbox:general` 이 만들어집니다. Debian slim 에 `bash`(턴이 `bash -l -s` 로
돕니다), `ripgrep`(Grep 도구가 `rg` 없이는 거부합니다), `git`, `curl`, 그리고 셸
턴이 손대는 몇 가지. 그 이상은 가정하지 않습니다. 프로젝트를 **빌드**해야 하는
Keeper 는 그 프로젝트의 툴체인이 필요하고, 그건 그 Keeper 의 TOML 에
`sandbox_image` 로 다른 이미지를 가리켜 해결합니다.

**샌드박스 런타임.** Docker, microVM, 또는 SSH 로 붙는 원격 호스트. **내 기계에서
그냥 돌리는 선택지는 없습니다.** [샌드박스](/ko/runbooks/sandbox/)를 보세요.

셋이 갖춰지면 TUI 의 **Keepers** 화면이나 `masc keeper-create --help` 로 첫 Keeper 를
만듭니다. [Keeper 운영하기](/ko/guides/keeper/)가 순서대로 안내합니다.

### 언어 서버는 따로입니다

Keeper 가 hover 나 정의로 가려면 샌드박스 `PATH` 에 언어 서버가 있어야 합니다. MASC 는
같이 배송하지 않고 대신 띄워 주지도 않습니다. 프로그램이 없으면 조용히 실패하지 않고
없다고 알려줍니다.

| 언어 | 프로그램 |
| --- | --- |
| OCaml | `ocamllsp` |
| TypeScript | `typescript-language-server` |
| JavaScript | `typescript-language-server` |
| Python | `pyright-langserver` |
| Rust | `rust-analyzer` |
| Go | `gopls` |
| C | `clangd` |
| C++ | `clangd` |
| Swift | `sourcekit-lsp` |
| Java | `jdtls` |
| Kotlin | `kotlin-language-server` |
| Ruby | `ruby-lsp` |
| PHP | `intelephense` |
| Lua | `lua-language-server` |
| Bash | `bash-language-server` |
| JSON | `vscode-json-language-server` |
| YAML | `yaml-language-server` |
| Zig | `zls` |
| Haskell | `haskell-language-server-wrapper` |
| Elixir | `elixir-ls` |
| Dart | `dart` |
| Scala | `metals` |
| C# | `csharp-ls` |
| Markdown | `marksman` |

## 잘 안 될 때

[문제 해결](/ko/runbooks/troubleshooting/)을 보세요. 첫 실행에서 가장 흔한 문제는
`masc: command not found` 입니다 — 위 2단계 PATH 문제입니다. 서버가 앞단에 머무르지
않고 시작하자마자 꺼지면, 문제 해결 문서에서 흔한 원인을 확인하세요.
