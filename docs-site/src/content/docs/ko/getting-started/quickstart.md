---
title: 빠른 시작
description: 보유 런타임을 연결하고 기본 샌드박스의 imp와 대화합니다.
---

macOS·Linux용 최신 공개 바이너리를 설치합니다. OCaml·Node.js 빌드 도구는 필요 없습니다.
[Releases](https://github.com/jeong-sik/masc/releases)에서 배포 버전과 지원 플랫폼을 확인하세요.

```bash
curl -fsSL https://github.com/jeong-sik/masc/releases/latest/download/install.sh \
  -o /tmp/masc-install.sh &&
bash /tmp/masc-install.sh
```

설치기가 작업 공간을 둘 디렉터리를 묻습니다. 이어서 설정할 때도 같은 경로를 사용하세요.
`--base-path`는 `.masc`가 **들어 있는 디렉터리**입니다. 스크립트를 먼저 읽으려면
다운로드 성공 후 `less /tmp/masc-install.sh`로 확인하고(`q`로 종료), `bash` 명령을 실행합니다.
특정 버전을 고정하려면 그 태그의 설치기를 받고 `--version TAG`도 지정해야 합니다.
자세한 예시는 [설치 가이드](https://github.com/jeong-sik/masc/blob/main/docs/INSTALL.ko.md)를 참고하세요.

## `imp`와 첫 대화

1. 모델 연결 하나를 준비합니다. 지원하는 CLI 구독과 해당 로그인, API 인증 정보,
   도구 호출을 지원하는 로컬 모델 서버 중 하나를 사용합니다. Claude Code·Codex 구독
   연결은 공식 CLI 계정을 사용하므로 별도 API 키가 필요하지 않습니다. 연결 검사 실패 시
   설정 화면에서 로그인 후 같은 선택으로 재시도할 수 있고, 계정 한도는 따로 표시합니다.
2. 설정 화면에서 샌드박스를 고릅니다. Docker, 지원되는 microVM, 원격 SSH는 각각 다른
   선택지입니다. Docker를 먼저 설치하지 않아도 MASC를 설치할 수 있습니다. 설정 화면은
   준비물을 확인하고 가능한 설치·시작 동작을 제공합니다. 이미지 준비와 Keeper 시작 성공은
   별도로 확인합니다.
3. 설정을 마쳐 작업 공간 서버와 `imp`를 준비하고 TUI를 엽니다. 선택적 음성과 호스트 도구는
   설정 도중이나 나중에 연결할 수 있습니다.

설정 화면이 열리지 않았거나 나중에 마치기로 했다면 다음을 실행하세요.

```bash
"$HOME/.local/bin/masc" setup
```

`--prefix`를 바꿨다면 그 실행 파일 경로를 사용하세요. 작업 공간을 직접 지정하려면 설치 때
고른 디렉터리로 `--base-path /path/to/your/workspace`를 덧붙입니다. PATH 추가 안내를
수락했다면 새 터미널에서 `masc`가 잡힙니다. 현재 터미널에는 기본 설치 경로 기준으로
`export PATH="$HOME/.local/bin:$PATH"`를 실행하세요.

기존 Keeper 설정은 보존합니다. 새로 시드한 `imp`의 기본값은
`activation_mode = "manual"`, `sandbox_profile = "docker"`,
`sandbox_image = "base"`, `network_mode = "inherit"`이며 설정 중 다른 실행 환경을
선택할 수 있습니다. 다른 작업 공간이 포트를 쓰면 `--port 8936`을 지정하세요.
대화형 여정은 TUI를 열기 전에 `--no-tui`로 서버를 준비하므로 대화 화면에서 나가도
준비된 서버는 계속 실행됩니다. 같은 작업 공간의 읽기 전용 상태 보고는 `masc doctor`로 확인합니다.

TUI에서 **Keepers → imp**를 선택하고 다음을 하나씩 요청하세요.

- “안녕. 대화가 연결됐는지 확인할 수 있게 답해줘.”
- “Board에 첫 대화라는 글을 작성하고 글 id를 알려줘.”
- “내 샌드박스 살펴보기라는 Task를 설명과 함께 만들고 id를 알려줘.”
- “네 샌드박스 안에서 `pwd`와 `ls`를 실행하고 디렉터리 목록을 보여줘.”
- “WebFetch로 지금 https://example.com 을 가져와서 HTTP 상태와 페이지 제목을 알려줘.”

답변, 저장된 Board 글과 Task, 샌드박스·웹 도구의 성공 결과를 확인하세요.
여기서는 대화와 기본 기능을 확인하며 Task 완료는 별도 절차입니다. Web fetch는
검색 API 키가 필요 없고 web search는 별도 검색 프로바이더 설정이 필요합니다.
어느 프로바이더가 빠졌는지는 `masc web-search-setup`으로 확인합니다.
도구 승인을 기다리면 채팅이나 **Approvals**에서 해당 요청을 확인하세요.
승인 대기나 HTTP 서버 응답만으로 모델 응답·도구 실행 성공을 판단하지 마세요.

플랫폼별 준비물과 업그레이드는 [설치 가이드](https://github.com/jeong-sik/masc/blob/main/docs/INSTALL.ko.md), TUI 키는 [터미널 UI](/ko/guides/tui/)를 참고하세요. MCP만 연결하려면 [외부 도구 연결](/ko/guides/mcp-clients/)을 따르세요.
