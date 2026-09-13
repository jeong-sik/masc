---
title: 빠른 시작
description: 보유 런타임을 연결하고 기본 샌드박스의 imp와 대화합니다.
---

macOS·Linux용 바이너리를 설치합니다. OCaml·Node.js 빌드 도구는 필요 없습니다.
이 안내는 **0.35.14** 기준입니다. 게시 여부는
[Releases](https://github.com/jeong-sik/masc/releases)에서 확인하고 바이너리와
같은 태그에 첨부된 설치기를 사용하세요.

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

## `imp`와 첫 대화 (0.35.14)

이 경로는 `masc setup`이 포함된 **0.35.14 설치 계약**입니다. 다운로드 전에
[GitHub Releases](https://github.com/jeong-sik/masc/releases)에서 태그와 자산 제공 여부를 확인하세요.

1. 설치 마법사를 `--base-path "$HOME/masc-workspace"`로 실행하고 보유한 모델
   런타임을 고릅니다. 런타임 설정의 `--setup-lanes`는 선택한 모델을 보조 판단
   레인에도 연결합니다. 두 번째 모델 구독은 필요하지 않습니다.
2. Claude Code·Codex는 CLI를 설치하고 해당 CLI에서 로그인한 뒤 이 터미널에서
   응답하는지 확인합니다. API 방식은 마법사에서 지정한 인증 환경변수를 이
   터미널에서 export합니다. 로컬 모델은 서버를 시작하고 도구 호출을 지원하는
   모델을 로드합니다. MASC는 모델 런타임을 설치하거나 대신 로그인하지 않습니다.
3. macOS에서는 Docker Desktop, Linux에서는 Docker Engine을 설치하고 시작합니다.
   현재 사용자로 `docker info`가 성공하면 다음을 실행합니다.

모델 번호를 고르거나 정확한 모델 ID를 입력하세요. 마법사는 context 한도의
출처를 표시하며, Codex에서 관측한 클라이언트 한도를 카탈로그보다 우선합니다.
한도를 알 수 없을 때만 문서에 명시된 값을 입력합니다. Claude Code·Codex는
도구 호출·streaming을 자동 설정합니다. Z.AI 인증 환경변수는 `ZAI_API_KEY`입니다.

```bash
masc setup --base-path "$HOME/masc-workspace"
```

`setup`은 누락된 설정을 시드하고 Docker 확인, 기본 샌드박스 이미지 빌드,
같은 작업 공간의 서버 시작·연결, `local-admin` 로그인, 기존 `imp` 시작을 거쳐
TUI를 엽니다. Keeper 설정 파일은 보존합니다. 기본 `imp` 설정은
`activation_mode = "manual"`, `sandbox_profile = "docker"`,
`network_mode = "inherit"`입니다. 다른 작업 공간이 포트를 쓰고 있으면
`--port 8936`처럼 빈 포트를 지정하세요. 종료할 때 setup이 직접 시작한 서버도
종료합니다. 서버를 계속 실행하려면 `--no-tui`를 사용하고 별도로 접속하세요.

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

플랫폼별 준비물과 업그레이드는 [설치 가이드](https://github.com/jeong-sik/masc/blob/main/docs/INSTALL.ko.md), TUI 키는 [터미널 UI](/ko/guides/tui/)를 참고하세요. MCP만 연결하려면 [외부 도구 연결](/ko/guides/mcp-clients/)을 따르세요.
